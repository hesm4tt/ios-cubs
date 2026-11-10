#!/bin/bash
# Image with the Sileo/Procursus prefix, the persistence job (cubs-persist.sh run) and the rwhttp client; rebuilds system.apfs (SYSTEM=1) and keeps
# a copy as ~/hopay/system-jb.apfs. Run on the Mac. JOBS_TAIL (env, optional) is appended to the job list (test jobs).
set -euo pipefail
U="$HOME/unixnu-pixel11/hackios-upstream"
test -x /tmp/cubs-launchd-extension-test
test -d "$U/jb/root/var/jb" || { echo "no jb prefix: run tools/mk-jb.sh first"; exit 1; }
cp "$HOME/cubs-persist.sh" "$U/jb/root/var/jb/etc/cubs-persist.sh"
chmod 755 "$U/jb/root/var/jb/etc/cubs-persist.sh"
printf '%s\n' 'exec /redwood/bin/cubs-launchd-extension-test' > /tmp/cubs-extension-watchdog.rc
cat > /tmp/cubs-persist-jobs <<'JOBS'
/redwood/bin/sound_test springboard
/redwood/bin/ps_loop 100 3 &
/redwood/bin/net_test wait 45 dhcp en0 waitaddr en0 60
/var/jb/bin/sh /var/jb/prep.sh
/var/jb/bin/sh /var/jb/etc/cubs-persist.sh run &
JOBS
printf '%s\n' "${JOBS_TAIL:-/redwood/bin/rwtouch wait 100}" >> /tmp/cubs-persist-jobs
RC_FILE=/tmp/cubs-extension-watchdog.rc \
JOBS_FILE=/tmp/cubs-persist-jobs \
IOS_EXTRA_OVERRIDE='com.apple.configd com.apple.mDNSResponder com.apple.mDNSResponderHelper com.apple.trustd com.apple.mediaserverd com.apple.nanoregistryd com.apple.nanoregistrylaunchd com.apple.PosterBoard' \
EXTRA_TEST_BIN="/tmp/cubs-launchd-extension-test $HOME/rwhttp" \
IMAGE_OUTPUT="${IMAGE_OUTPUT:-$HOME/hopay/root_cubs_persist.apfs}" \
  bash "$HOME/build_jb_image.sh"
echo persist-image-built
