#!/bin/bash
set -euo pipefail
test -x /tmp/cubs-launchd-extension-test
test -f /tmp/libcubs-about.dylib
printf '%s\n' 'exec /redwood/bin/cubs-launchd-extension-test' > /tmp/cubs-extension-watchdog.rc
cat > /tmp/cubs-about-production-jobs <<'JOBS'
/redwood/bin/ps_loop 100 3 &
/redwood/bin/net_test wait 45 dhcp en0 waitaddr en0 60
JOBS
RC_FILE=/tmp/cubs-extension-watchdog.rc \
JOBS_FILE=/tmp/cubs-about-production-jobs \
IOS_EXTRA_OVERRIDE='com.apple.configd com.apple.mDNSResponder com.apple.mDNSResponderHelper com.apple.trustd com.apple.mediaserverd com.apple.nanoregistryd com.apple.nanoregistrylaunchd com.apple.PosterBoard' \
EXTRA_TEST_BIN='/tmp/cubs-launchd-extension-test /tmp/libcubs-about.dylib' \
INJECT_EXTRA='/redwood/bin/libcubs-about.dylib Preferences' \
IMAGE_OUTPUT="$HOME/hopay/root_cubs_about_production.apfs" \
  bash /tmp/build_battery_test_image.sh
