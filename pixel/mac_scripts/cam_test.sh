#!/bin/bash
# Camera viewfinder probe image (run on the Mac): CamProbe.app (pcwork/jb/camprobe.m, signed with camprobe.entitlements) is baked into the system
# image's /Applications, sbslaunch starts it after the unlock swipe; payload cubscp has the fake camera args (the kernel's chart frames, no Android
# camera). The app is removed from the userland apps dir after the build. Then run_cam.sh pushes the system image as system-jbtest.img.
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
cd "$HOME"
source "$HOME/unixnu-pixel11/hackios-upstream/xnu-env.sh"
export THEOS="$HOME/unixnu-pixel11/theos"
U="$HOME/unixnu-pixel11/hackios-upstream"
APP="$U/apps/CamProbe.app"
cleanup() { rm -rf "$APP"; }
trap cleanup EXIT
rm -rf "$APP"; mkdir -p "$APP"
xnu-clang -arch arm64 -isysroot "$THEOS/sdks/iPhoneOS16.5.sdk" -fno-objc-arc -O1 -Wno-deprecated-declarations -o "$APP/CamProbe" camprobe.m \
	-framework Foundation -framework UIKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework CoreImage -framework QuartzCore -framework CoreGraphics -framework IOSurface -lobjc
ldid -S"$HOME/camprobe.entitlements" "$APP/CamProbe"
python3 - "$HOME/metaldemo.plist" "$APP/Info.plist" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
d['CFBundleIdentifier'] = 'com.cubs.camprobe'
d['CFBundleExecutable'] = 'CamProbe'
d['CFBundleName'] = 'CamProbe'
d['CFBundleDisplayName'] = 'CamProbe'
d['NSCameraUsageDescription'] = 'camera probe'
d.pop('CFBundleURLTypes', None)
plistlib.dump(d, open(sys.argv[2], 'wb'))
PY
cp "$U/apps/MetalDemo.app/AppIcon60x60@2x.png" "$U/apps/MetalDemo.app/AppIcon60x60@3x.png" "$APP/"
printf 'APPL????' > "$APP/PkgInfo"
xnu-clang -arch arm64 -isysroot "$THEOS/sdks/iPhoneOS16.5.sdk" -O1 -framework CoreFoundation -o sbslaunch sbslaunch.c
ldid -S"$HOME/lsprobe.entitlements" sbslaunch
perl -pe 's#\$HOME/rwhttp"#\$HOME/rwhttp \$HOME/sbslaunch"#' build_persist_image.sh > build_persist_cam_image.sh
export JOBS_TAIL='/redwood/bin/rwtouch wait 20 swipe 0.5 0.985 0.5 0.3 250 wait 3
/redwood/bin/sbslaunch com.cubs.camprobe
/redwood/bin/rwtouch wait 70
/var/jb/bin/cat /tmp/camprobe.log
/redwood/bin/rwtouch wait 20'
export INJECT_EXTRA='/redwood/bin/libmgcam.dylib CamProbe'
export IMAGE_OUTPUT="$HOME/hopay/root_cubs_cam.apfs"
bash build_persist_cam_image.sh
unset JOBS_TAIL
PAYLOAD_NAME=cubscp ROOT_IMAGE="$HOME/hopay/root_cubs_cam.apfs" BOOT_EXTRA="cubs_shot=1 cubs_sound=1 cubs_hb=1 cam=5 cam_fake=1 cam_fake_fps=15 cam_bridge=1 cam_shutter=6000 surftrace_of=mediaserverd surftrace=40" bash build_big_payload.sh
echo BUILD-OK
