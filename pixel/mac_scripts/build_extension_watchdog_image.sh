#!/bin/bash
set -euo pipefail
test -x /tmp/cubs-launchd-extension-test
printf '%s\n' 'exec /redwood/bin/cubs-launchd-extension-test' > /tmp/cubs-extension-watchdog.rc
RC_FILE=/tmp/cubs-extension-watchdog.rc \
EXTRA_TEST_BIN=/tmp/cubs-launchd-extension-test \
IMAGE_OUTPUT="$HOME/hopay/root_cubs_extension_watchdog.apfs" \
  bash /tmp/build_battery_test_image.sh
