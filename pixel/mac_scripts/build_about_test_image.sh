#!/bin/bash
set -euo pipefail
test -x /tmp/cubs-launchd-extension-test
test -f /tmp/libcubs-about.dylib
printf '%s\n' 'exec /redwood/bin/cubs-launchd-extension-test' > /tmp/cubs-extension-watchdog.rc
cat > /tmp/cubs-about-jobs <<'JOBS'
/redwood/bin/ps_loop 100 3 &
/redwood/bin/net_test wait 45 dhcp en0 waitaddr en0 60 &
/redwood/bin/rwtouch wait 95 swipe 0.5 0.985 0.5 0.3 250 wait 8
/redwood/bin/battery_test open prefs:root=General&path=About
JOBS
RC_FILE=/tmp/cubs-extension-watchdog.rc \
JOBS_FILE=/tmp/cubs-about-jobs \
IOS_EXTRA_OVERRIDE='com.apple.configd com.apple.mDNSResponder com.apple.mDNSResponderHelper com.apple.trustd com.apple.mediaserverd com.apple.nanoregistryd com.apple.nanoregistrylaunchd com.apple.PosterBoard' \
EXTRA_TEST_BIN='/tmp/cubs-launchd-extension-test /tmp/libcubs-about.dylib' \
INJECT_EXTRA='/redwood/bin/libcubs-about.dylib Preferences' \
IMAGE_OUTPUT="$HOME/hopay/root_cubs_about_test.apfs" \
  bash /tmp/build_battery_test_image.sh
