#!/bin/bash
set -euo pipefail
U="$HOME/unixnu-pixel11/hackios-upstream/userland"
T=$(mktemp -d /tmp/cubs-battery-image.XXXXXX)
cp -p "$U/root.apfs" "$T/root.apfs"
cleanup() { cp -p "$T/root.apfs" "$U/root.apfs"; }
trap cleanup EXIT
cat > "$T/jobs" <<'JOBS'
/redwood/bin/ps_loop 100 3 &
/redwood/bin/net_test wait 45 dhcp en0 waitaddr en0 60 &
/redwood/bin/rwtouch wait 80
/redwood/bin/battery_test 3 5
JOBS
export PATH="$PATH:/opt/homebrew/bin"
export THEOS="$HOME/unixnu-pixel11/theos"
export INJECT="$(cat "$HOME/inject_all.txt")"
if [ -n "${INJECT_EXTRA:-}" ]; then INJECT="$INJECT
$INJECT_EXTRA"; export INJECT; fi
export IOS_EXTRA="${IOS_EXTRA_OVERRIDE:-com.apple.configd com.apple.mDNSResponder com.apple.mDNSResponderHelper com.apple.trustd com.apple.mediaserverd com.apple.nanoregistryd com.apple.nanoregistrylaunchd com.apple.PosterBoard com.apple.wifid}"
export JOB_PROGRAM='com.apple.mobilegestalt.xpc=/redwood/bin/mghelper'
export EXTRA_LIB="$HOME/libredwood-gl.dylib"
export EXTRA="$HOME/ps_loop $HOME/mghelper $HOME/libmgpatch.dylib $HOME/libmgcam.dylib ${EXTRA_TEST_BIN:-}"
cd "$U"
RC="${RC_FILE:-rc.launchd}" RC_JOBS="${JOBS_FILE:-$T/jobs}" bash build.sh > /tmp/cubs-battery-image-build.log 2>&1
cp root.apfs "${IMAGE_OUTPUT:-$HOME/hopay/root_cubsbatt_test.apfs}"
echo battery-test-image-built
