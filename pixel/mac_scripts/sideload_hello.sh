#!/bin/bash
# The sideload test package (run on the Mac, phone in Android): hello.m as an IPA (bundle id com.cubs.persisttest, scheme persisttest) -> .deb with
# ipa2deb.sh -> the phone's inbox (/data/local/ios/inbox), replacing the MetalDemo clone the earlier sideload tests used (that one died at load for
# want of libmtlshim). persist.tar is emptied so the next boot installs it fresh.
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
cd "$HOME"
source "$HOME/unixnu-pixel11/hackios-upstream/xnu-env.sh"
export THEOS="$HOME/unixnu-pixel11/theos"
rm -rf /tmp/pt5; mkdir -p /tmp/pt5/Payload/PersistTest.app
A=/tmp/pt5/Payload/PersistTest.app
xnu-clang -arch arm64 -isysroot "$THEOS/sdks/iPhoneOS16.5.sdk" -fno-objc-arc -O1 -o "$A/PersistTest" hello.m -framework Foundation -framework UIKit -lobjc
python3 - "$HOME/metaldemo.plist" "$A/Info.plist" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
d['CFBundleIdentifier'] = 'com.cubs.persisttest'
d['CFBundleExecutable'] = 'PersistTest'
d['CFBundleName'] = 'PersistTest'
d['CFBundleDisplayName'] = 'PersistTest'
d['CFBundleURLTypes'] = [{'CFBundleURLName': 'com.cubs.persisttest', 'CFBundleURLSchemes': ['persisttest']}]
plistlib.dump(d, open(sys.argv[2], 'wb'))
PY
cp "$HOME/unixnu-pixel11/hackios-upstream/apps/MetalDemo.app/AppIcon60x60@2x.png" "$HOME/unixnu-pixel11/hackios-upstream/apps/MetalDemo.app/AppIcon60x60@3x.png" "$A/"
printf 'APPL????' > "$A/PkgInfo"
( cd /tmp/pt5 && rm -f hello.ipa && zip -qr hello.ipa Payload )
bash "$HOME/ipa2deb.sh" /tmp/pt5/hello.ipa /tmp/pt5/persisttest.deb
adb push /tmp/pt5/persisttest.deb /data/local/tmp/persisttest.deb >/dev/null
printf 'rm -f /data/local/ios/inbox/*.deb /data/local/ios/persist.tar /data/local/ios/persist.tar.prev; cp /data/local/tmp/persisttest.deb /data/local/ios/inbox/; ls -la /data/local/ios/inbox\n' | adb shell /data/adb/ksu/bin/ksud debug su
