#!/bin/bash
# Test image: same normal jobs as the wallpaper test plus a long tone and repeated volume presses.
set -euo pipefail
test -x /tmp/cubs-launchd-extension-test
printf '%s\n' 'exec /redwood/bin/cubs-launchd-extension-test' > /tmp/cubs-extension-watchdog.rc
cat > /tmp/cubs-volsound-jobs <<'JOBS'
/redwood/bin/ps_loop 100 3 &
/redwood/bin/net_test wait 45 dhcp en0 waitaddr en0 60 &
/redwood/bin/sound_test springboard route wait 2 tone 150 &
/redwood/bin/rwtouch wait 125 button volup wait 3 button volup wait 3 button volup wait 3 button volup wait 3 button voldown wait 3 button volup wait 3 button volup wait 3 button volup wait 3 button volup wait 3 button volup
JOBS
RC_FILE=/tmp/cubs-extension-watchdog.rc \
JOBS_FILE=/tmp/cubs-volsound-jobs \
IOS_EXTRA_OVERRIDE='com.apple.configd com.apple.mDNSResponder com.apple.mDNSResponderHelper com.apple.trustd com.apple.mediaserverd com.apple.nanoregistryd com.apple.nanoregistrylaunchd com.apple.PosterBoard' \
EXTRA_TEST_BIN=/tmp/cubs-launchd-extension-test \
IMAGE_OUTPUT="$HOME/hopay/root_cubs_volsound.apfs" \
  bash /tmp/build_battery_test_image.sh
