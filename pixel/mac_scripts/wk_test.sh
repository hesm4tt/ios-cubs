#!/bin/bash
# WKWebView probe test image (run on the Mac): WKProbe.app (pcwork/jb/wkprobe.m) is baked into the system image's /Applications, sbslaunch starts it
# after the unlock swipe. The app is removed from the userland apps dir again afterwards so that no later system image carries it.
# Then run_wk.sh pushes the system image as system-jbtest.img for one supervised boot.
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
cd "$HOME"
source "$HOME/unixnu-pixel11/hackios-upstream/xnu-env.sh"
export THEOS="$HOME/unixnu-pixel11/theos"
U="$HOME/unixnu-pixel11/hackios-upstream"
APP="$U/apps/WKProbe.app"
cleanup() { rm -rf "$APP"; }
trap cleanup EXIT
rm -rf "$APP"; mkdir -p "$APP"
xnu-clang -arch arm64 -isysroot "$THEOS/sdks/iPhoneOS16.5.sdk" -fno-objc-arc -O1 -Wno-deprecated-declarations -o "$APP/WKProbe" wkprobe.m \
	-framework Foundation -framework UIKit -framework WebKit -framework QuartzCore -framework CoreGraphics -lobjc
python3 - "$HOME/metaldemo.plist" "$APP/Info.plist" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
d['CFBundleIdentifier'] = 'com.cubs.wkprobe'
d['CFBundleExecutable'] = 'WKProbe'
d['CFBundleName'] = 'WKProbe'
d['CFBundleDisplayName'] = 'WKProbe'
d.pop('CFBundleURLTypes', None)
plistlib.dump(d, open(sys.argv[2], 'wb'))
PY
cp "$U/apps/MetalDemo.app/AppIcon60x60@2x.png" "$U/apps/MetalDemo.app/AppIcon60x60@3x.png" "$APP/"
printf 'APPL????' > "$APP/PkgInfo"
xnu-clang -arch arm64 -isysroot "$THEOS/sdks/iPhoneOS16.5.sdk" -O1 -framework CoreFoundation -o sbslaunch sbslaunch.c
xnu-clang -arch arm64 -isysroot "$THEOS/sdks/iPhoneOS16.5.sdk" -fno-objc-arc -O1 -dynamiclib -framework Foundation -framework CoreGraphics -lobjc -o libwkfix.dylib libwkfix.m
ldid -S"$HOME/lsprobe.entitlements" sbslaunch
perl -pe 's#\$HOME/rwhttp"#\$HOME/rwhttp \$HOME/sbslaunch"#; $_ .= "mkdir -p \"\$U/jb/root/var/jb/usr/lib\"
cp \"\$HOME/libwkfix.dylib\" \"\$U/jb/root/var/jb/usr/lib/libwkfix.dylib\"
chmod 755 \"\$U/jb/root/var/jb/usr/lib/libwkfix.dylib\"
" if /^chmod 755 .*cubs-persist\.sh/' build_persist_image.sh > build_persist_wk_image.sh
export JOBS_TAIL='/redwood/bin/rwtouch wait 20 swipe 0.5 0.985 0.5 0.3 250 wait 3
/redwood/bin/sbslaunch com.cubs.wkprobe
/redwood/bin/rwtouch wait 50
/redwood/bin/battery_test open https://example.com/
/redwood/bin/rwtouch wait 45
/var/jb/bin/cat /tmp/wkprobe.log /tmp/wkfix.log
/redwood/bin/rwtouch wait 20'
export IMAGE_OUTPUT="$HOME/hopay/root_cubs_wk.apfs"
bash build_persist_wk_image.sh
unset JOBS_TAIL
PAYLOAD_NAME=cubswk ROOT_IMAGE="$HOME/hopay/root_cubs_wk.apfs" BOOT_EXTRA="cubs_shot=1 cubs_sound=1 cubs_hb=1" bash build_big_payload.sh
echo BUILD-OK
