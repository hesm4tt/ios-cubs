#!/bin/bash
# Test image: cg_test (CoreGraphics into IOSurface: CGIOSurfaceContextCreate vs a plain bitmap context) as the only job.
set -euo pipefail
test -x /tmp/cubs-launchd-extension-test
printf '%s\n' 'exec /redwood/bin/cubs-launchd-extension-test' > /tmp/cubs-extension-watchdog.rc
cat > /tmp/cubs-cgtest-jobs <<'JOBS'
/redwood/bin/cg_test
/redwood/bin/rwtouch wait 5
/redwood/bin/cg_test
/redwood/bin/rwtouch wait 60
JOBS
RC_FILE=/tmp/cubs-extension-watchdog.rc \
JOBS_FILE=/tmp/cubs-cgtest-jobs \
IOS_EXTRA_OVERRIDE='com.apple.configd com.apple.mDNSResponder com.apple.mDNSResponderHelper com.apple.trustd com.apple.mediaserverd com.apple.nanoregistryd com.apple.nanoregistrylaunchd com.apple.PosterBoard' \
EXTRA_TEST_BIN=/tmp/cubs-launchd-extension-test \
IMAGE_OUTPUT="$HOME/hopay/root_cubs_cgtest.apfs" \
  bash /tmp/build_battery_test_image.sh
