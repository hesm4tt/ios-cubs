#!/bin/bash
set -euo pipefail
U="$HOME/unixnu-pixel11/hackios-upstream/userland"
T=$(mktemp -d /tmp/cubs-late-wifi.XXXXXX)
cp -p "$U/root.apfs" "$T/root.apfs"
cleanup() { cp -p "$T/root.apfs" "$U/root.apfs"; }
trap cleanup EXIT
cat > "$T/jobs" <<'JOBS'
/redwood/bin/ps_loop 100 3 &
/redwood/bin/net_test wait 45 dhcp en0 waitaddr en0 60
/redwood/bin/sound_test springboard
/redwood/bin/battery_test open prefs:root=WIFI
/redwood/bin/net_test show dhcp en0 waitaddr en0 30 resolve example.com fetch https://example.com/ &
/redwood/bin/rwtouch wait 105
/redwood/bin/battery_test open prefs:root=WIFI
/redwood/bin/rwtouch wait 90
JOBS
export PATH="$PATH:/opt/homebrew/bin"
export THEOS="$HOME/unixnu-pixel11/theos"
export INJECT="$(cat "$HOME/inject_all.txt")"
export IOS_EXTRA='com.apple.configd com.apple.mDNSResponder com.apple.mDNSResponderHelper com.apple.trustd com.apple.mediaserverd com.apple.nanoregistryd com.apple.nanoregistrylaunchd com.apple.PosterBoard com.apple.wifid'
export JOB_PROGRAM='com.apple.mobilegestalt.xpc=/redwood/bin/mghelper'
export EXTRA_LIB="$HOME/libredwood-gl.dylib"
export EXTRA="$HOME/ps_loop $HOME/mghelper $HOME/libmgpatch.dylib $HOME/libmgcam.dylib"
cd "$U"
RC_JOBS="$T/jobs" bash build.sh > /tmp/cubs-late-wifi-build.log 2>&1
cp root.apfs "$HOME/hopay/root_cubsscan_late.apfs"
echo late-test-image-built
