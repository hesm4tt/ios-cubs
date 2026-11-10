#!/bin/bash
# Test image: HTTPS reliability (several hosts, TLS chain, Safari) on the production job set.
set -euo pipefail
test -x /tmp/cubs-launchd-extension-test
printf '%s\n' 'exec /redwood/bin/cubs-launchd-extension-test' > /tmp/cubs-extension-watchdog.rc
cat > /tmp/cubs-https-jobs <<'JOBS'
/redwood/bin/net_test wait 45 show dhcp en0 waitaddr en0 60 resolve example.com fetch https://example.com/ fetch https://www.google.com/ fetch https://github.com/ fetch https://www.cloudflare.com/ &
/redwood/bin/rwtouch wait 20 swipe 0.5 0.985 0.5 0.3 250 wait 8
/redwood/bin/rwtouch wait 40
/redwood/bin/battery_test open https://example.com/
/redwood/bin/rwtouch wait 20
JOBS
RC_FILE=/tmp/cubs-extension-watchdog.rc \
JOBS_FILE=/tmp/cubs-https-jobs \
IOS_EXTRA_OVERRIDE='com.apple.configd com.apple.mDNSResponder com.apple.mDNSResponderHelper com.apple.trustd com.apple.mediaserverd com.apple.nanoregistryd com.apple.nanoregistrylaunchd com.apple.PosterBoard' \
EXTRA_TEST_BIN=/tmp/cubs-launchd-extension-test \
IMAGE_OUTPUT="$HOME/hopay/root_cubs_https.apfs" \
  bash /tmp/build_battery_test_image.sh
