#!/bin/bash
# Test image: Safari opened as early as possible after the unlock swipe, so the first seconds of WebContent/IOSurface logs fit in the kernel log window.
set -euo pipefail
test -x /tmp/cubs-launchd-extension-test
printf '%s\n' 'exec /redwood/bin/cubs-launchd-extension-test' > /tmp/cubs-extension-watchdog.rc
cat > /tmp/cubs-safari-jobs <<'JOBS'
/redwood/bin/net_test wait 20 show dhcp en0 waitaddr en0 60 resolve example.com fetch https://example.com/ &
/redwood/bin/rwtouch wait 8 swipe 0.5 0.985 0.5 0.3 250 wait 3
/redwood/bin/battery_test open https://example.com/
/redwood/bin/rwtouch wait 60
JOBS
RC_FILE=/tmp/cubs-extension-watchdog.rc \
JOBS_FILE=/tmp/cubs-safari-jobs \
IOS_EXTRA_OVERRIDE='com.apple.configd com.apple.mDNSResponder com.apple.mDNSResponderHelper com.apple.trustd com.apple.mediaserverd com.apple.nanoregistryd com.apple.nanoregistrylaunchd com.apple.PosterBoard' \
EXTRA_TEST_BIN=/tmp/cubs-launchd-extension-test \
IMAGE_OUTPUT="$HOME/hopay/root_cubs_safari.apfs" \
  bash /tmp/build_battery_test_image.sh
