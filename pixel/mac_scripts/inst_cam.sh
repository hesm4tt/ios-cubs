#!/bin/bash
# Install the production payload with the Android-camera bridge (cam=5 cam_fake=1 cam_bridge=1) and the flags that start the Android camera 110 s after launch.
# Rollback on the phone: cp ho.payload.pre-cam ho.payload.prod; cp ho.payload.pre-cam ho.payload; rm cam camid camdelay
set -eu
export PATH="$PATH:/opt/homebrew/bin"
read -r ram list < /tmp/cubsfinalcam-offsets
[ "$ram" = 28b4000 ] && [ "$list" = 17fe00000 ] || { echo offsets-mismatch; exit 1; }
[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ] || { echo android-not-ready; exit 1; }
adb push "$HOME/pcwork/hopay2/cubsfinalcamr.payload" /data/local/tmp/cubsfinalcam.payload >/dev/null
printf '%s\n' 'set -e
D=/data/local/ios
cmp -s "$D/ho.payload" "$D/ho.payload.prod" || exit 1
for f in boot_ios smp cam camid camdelay noring cpu6_khz; do test ! -e "$D/$f" || exit 1; done
test ! -e "$D/ho.payload.pre-cam" || exit 1
cp "$D/ho.payload.prod" "$D/ho.payload.pre-cam"
cp /data/local/tmp/cubsfinalcam.payload "$D/ho.payload.new-cam"
cmp -s /data/local/tmp/cubsfinalcam.payload "$D/ho.payload.new-cam" || exit 1
cp "$D/ho.payload.new-cam" "$D/ho.payload.prod.new-cam"
mv -f "$D/ho.payload.prod.new-cam" "$D/ho.payload.prod"
mv -f "$D/ho.payload.new-cam" "$D/ho.payload"
touch "$D/cam"; echo 1 > "$D/camid"; echo 110 > "$D/camdelay"
sync
cmp -s "$D/ho.payload" "$D/ho.payload.prod" || exit 1
rm -f /data/local/tmp/cubsfinalcam.payload
echo cam-production-installed' | adb shell /data/adb/ksu/bin/ksud debug su
