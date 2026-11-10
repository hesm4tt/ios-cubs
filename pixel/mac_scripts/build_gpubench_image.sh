#!/bin/bash
# GPU benchmark image: home-screen page flips (swipes) with ps_loop (per-process CPU) running; read the "frames in 5000 ms" lines
# (MiniIOMobileFramebuffer), "redwood-gl: frame N" and "forward:" lines from the kernel log with logfix.py.
set -euo pipefail
test -x /tmp/cubs-launchd-extension-test
printf '%s\n' 'exec /redwood/bin/cubs-launchd-extension-test' > /tmp/cubs-extension-watchdog.rc
{
echo '/redwood/bin/ps_loop 100 5 &'
echo '/redwood/bin/net_test wait 20 dhcp en0 waitaddr en0 60 &'
echo '/redwood/bin/rwtouch wait 25 swipe 0.5 0.985 0.5 0.3 250 wait 15'
for i in 1 2 3 4 5 6; do
  echo '/redwood/bin/rwtouch swipe 0.9 0.45 0.1 0.45 300 wait 2 swipe 0.1 0.45 0.9 0.45 300 wait 2'
done
echo '/redwood/bin/rwtouch wait 20'
} > /tmp/cubs-gpubench-jobs
RC_FILE=/tmp/cubs-extension-watchdog.rc \
JOBS_FILE=/tmp/cubs-gpubench-jobs \
IOS_EXTRA_OVERRIDE='com.apple.configd com.apple.mDNSResponder com.apple.mDNSResponderHelper com.apple.trustd com.apple.mediaserverd com.apple.nanoregistryd com.apple.nanoregistrylaunchd com.apple.PosterBoard' \
EXTRA_TEST_BIN=/tmp/cubs-launchd-extension-test \
IMAGE_OUTPUT="$HOME/hopay/root_cubs_gpubench.apfs" \
  bash /tmp/build_battery_test_image.sh
