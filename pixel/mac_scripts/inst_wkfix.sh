#!/bin/bash
# inst_wkfix.sh (inst_bright.sh with the backup name .pre-wkfix): install the rebuilt production system image (~/hopay/system-jb.apfs: prefix with brightbridge, started by cubs-persist.sh, and the
# bundle-container registration + one SpringBoard restart for sideloaded apps) as /data/local/ios/system-jb.img. Run on the Mac, phone in Android.
# The Android end (persistsrv with the /brightness handler) was installed before (backup persistsrv.pre-wkfix).
# Rollback on the phone:  cd /data/local/ios; cp system-jb.img.pre-wkfix system-jb.img.n && mv -f system-jb.img.n system-jb.img
#                         (and  cp persistsrv.pre-wkfix persistsrv  to drop the Android handler)
set -eu
export PATH="$PATH:/opt/homebrew/bin"
S=$HOME/hopay/system-jb.apfs
SZ=$(stat -f %z "$S")
[ "$SZ" -le 2559852544 ] || { echo "image bigger than the RAM-disk reserve"; exit 1; }
[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ] || { echo android-not-ready; exit 1; }
rootsh() { printf '%s\n' "$1" | adb shell /data/adb/ksu/bin/ksud debug su; }
rootsh 'D=/data/local/ios; test "$(stat -c %s $D/system-jb.img)" = 2543075328 && cmp $D/ho.payload $D/ho.payload.prod && for f in boot_ios smp noring cpu6_khz system-jbtest.img; do test ! -e $D/$f || exit 1; done; echo preflight-ok' | grep preflight-ok >/dev/null
adb push "$S" /data/local/tmp/system-jb.new >/dev/null
rootsh "SZ=$SZ; "'D=/data/local/ios; set -e; test "$(stat -c %s /data/local/tmp/system-jb.new)" = $SZ; cp -p $D/system-jb.img $D/system-jb.img.pre-wkfix; cmp $D/system-jb.img $D/system-jb.img.pre-wkfix; cp /data/local/tmp/system-jb.new $D/system-jb.img.n; mv -f $D/system-jb.img.n $D/system-jb.img; rm -f /data/local/tmp/system-jb.new; sync; ls -la $D/system-jb.img $D/system-jb.img.pre-wkfix; echo bright-production-installed'
