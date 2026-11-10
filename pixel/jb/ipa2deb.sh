#!/bin/bash
# ipa2deb.sh app.ipa [OUT.deb]: turn an (unsigned) .ipa into a rootless Debian package that installs the app into /var/jb/Applications
# (cubs-persist.sh / Sileo / dpkg -i then uicache register it). No dpkg-deb needed: a .deb is an ar archive of debian-binary, control.tar and data.tar.
set -euo pipefail
IPA=${1:?usage: ipa2deb.sh app.ipa [out.deb]}
T=$(mktemp -d /tmp/ipa2deb.XXXXXX); trap 'rm -rf "$T"' EXIT
unzip -q "$IPA" -d "$T/ipa"
APP=$(ls -d "$T"/ipa/Payload/*.app | head -n 1)
NAME=$(basename "$APP" .app)
BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist" 2>/dev/null || plutil -extract CFBundleIdentifier raw "$APP/Info.plist")
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist" 2>/dev/null || echo 1.0)
PKG=$(echo "$BID" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9.+\n-' '-')
OUT=${2:-$PWD/$PKG.deb}
mkdir -p "$T/data/var/jb/Applications" "$T/ctl"
cp -aL "$APP" "$T/data/var/jb/Applications/"
cat > "$T/ctl/control" <<CTL
Package: $PKG
Name: $NAME
Version: $VER
Architecture: iphoneos-arm64
Description: $NAME (sideloaded IPA)
Maintainer: cubs
Section: Applications
CTL
printf '#!/var/jb/bin/sh\n/var/jb/usr/bin/uicache -a >/dev/null 2>&1\nexit 0\n' > "$T/ctl/postinst"
chmod 755 "$T/ctl/postinst"
printf '2.0\n' > "$T/debian-binary"
( cd "$T/ctl" && tar -cf "$T/control.tar" . )
( cd "$T/data" && tar -cf "$T/data.tar" . )
# a .deb needs the common "ar" format with the members in this order and no symbol table (macOS ar -r would add __.SYMDEF): written by hand
python3 - "$OUT" "$T/debian-binary" "$T/control.tar" "$T/data.tar" <<'PY'
import os, sys
out = sys.argv[1]
with open(out, 'wb') as f:
    f.write(b'!<arch>\n')
    for p in sys.argv[2:]:
        d = open(p, 'rb').read()
        name = os.path.basename(p).encode() + b'/'
        f.write(name.ljust(16) + b'0'.ljust(12) + b'0'.ljust(6) + b'0'.ljust(6) + b'100644'.ljust(8) + str(len(d)).encode().ljust(10) + b'`\n')
        f.write(d)
        if len(d) % 2:
            f.write(b'\n')
PY
echo "ipa2deb: $OUT ($NAME, $BID, $(du -h "$OUT" | cut -f1))"
