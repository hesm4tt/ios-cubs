#!/bin/bash
# Microphone test image (run on the Mac): MicTest.app (pcwork/jb/mictest.m, shows the live level) baked into the system image's /Applications, sbslaunch starts it
# after the unlock swipe; libtf.dylib (= pcwork/jb/libtccfake.m, answers the privacy checks "granted") is put into /redwood/lib and named in inject.conf for
# mediaserverd. userland/root/etc/inject.conf and the lib are restored/removed afterwards (trap), the app is removed from the apps dir again.
# Then run_mic2.sh pushes the system image as system-jbtest.img for one supervised boot (payload cubsmict = this root + cubs_mic=1).
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
cd "$HOME"
source "$HOME/unixnu-pixel11/hackios-upstream/xnu-env.sh"
export THEOS="$HOME/unixnu-pixel11/theos"
U="$HOME/unixnu-pixel11/hackios-upstream"
SDK="$THEOS/sdks/iPhoneOS16.5.sdk"
APP="$U/apps/MicTest.app"
INJ="$U/userland/root/etc/inject.conf"
cp "$INJ" /tmp/inject.conf.pre-mic
cleanup() { rm -rf "$APP" "$U/userland/root/lib/libtf.dylib"; cp /tmp/inject.conf.pre-mic "$INJ"; }
trap cleanup EXIT
rm -rf "$APP"; mkdir -p "$APP"
xnu-clang -arch arm64 -isysroot "$SDK" -fno-objc-arc -O1 -Wno-deprecated-declarations -F"$SDK/System/Library/PrivateFrameworks" -I"$HOME" \
	-o "$APP/MicTest" mictest.m -framework Foundation -framework UIKit -framework AVFoundation -framework QuartzCore -framework TCC -lobjc
python3 - "$HOME/metaldemo.plist" "$APP/Info.plist" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
d['CFBundleIdentifier'] = 'com.cubs.mictest'
d['CFBundleExecutable'] = 'MicTest'
d['CFBundleName'] = 'MicTest'
d['CFBundleDisplayName'] = 'MicTest'
d['NSMicrophoneUsageDescription'] = 'microphone test'
d.pop('CFBundleURLTypes', None)
plistlib.dump(d, open(sys.argv[2], 'wb'))
PY
cp "$U/apps/MetalDemo.app/AppIcon60x60@2x.png" "$U/apps/MetalDemo.app/AppIcon60x60@3x.png" "$APP/"
printf 'APPL????' > "$APP/PkgInfo"
xnu-clang -arch arm64 -isysroot "$SDK" -O1 -framework CoreFoundation -o sbslaunch sbslaunch.c
ldid -S"$HOME/lsprobe.entitlements" sbslaunch
xnu-clang -arch arm64 -isysroot "$SDK" -fno-objc-arc -O1 -dynamiclib -F"$SDK/System/Library/PrivateFrameworks" -framework Foundation -framework TCC -lobjc \
	-install_name /redwood/bin/libtf.dylib -o libtf.dylib libtccfake.m
# (the image builder takes its injection list from ~/inject_all.txt + $INJECT_EXTRA, not from inject.conf, and copies EXTRA_TEST_BIN files to /redwood/bin)
export INJECT_EXTRA='/redwood/bin/libtf.dylib mediaserverd MicTest'
perl -pe 's#\$HOME/rwhttp"#\$HOME/rwhttp \$HOME/sbslaunch \$HOME/libtf.dylib"#' build_persist_image.sh > build_persist_mic_image.sh
grep -c libtf build_persist_mic_image.sh
export JOBS_TAIL='/redwood/bin/rwtouch wait 20 swipe 0.5 0.985 0.5 0.3 250 wait 3
/redwood/bin/sbslaunch com.cubs.mictest
/redwood/bin/rwtouch wait 40
/var/jb/bin/cat /tmp/mictest.log /tmp/tccfake.log
/redwood/bin/rwtouch wait 40
/var/jb/bin/cat /tmp/mictest.log /tmp/tccfake.log
/redwood/bin/rwtouch wait 40
/var/jb/bin/cat /tmp/mictest.log /tmp/tccfake.log
/redwood/bin/rwtouch wait 20'
export IMAGE_OUTPUT="$HOME/hopay/root_cubs_mic.apfs"
bash build_persist_mic_image.sh
unset JOBS_TAIL
PAYLOAD_NAME=cubsmict ROOT_IMAGE="$HOME/hopay/root_cubs_mic.apfs" BOOT_EXTRA="cubs_wifi=1 cubs_shot=1 cubs_hb=1 cubs_sound=1 cubs_mic=1" bash build_big_payload.sh
echo BUILD-OK
