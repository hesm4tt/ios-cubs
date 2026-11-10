#!/bin/bash
# One bounded production-payload run; phone watchdog restores the launcher.
# Disabled: the timing and recovery checks failed during the first live run.
echo 'disabled: live watchdog and recovery checks failed' >&2
exit 1
set -u
export PATH=$PATH:/opt/homebrew/bin
rootsh() { printf '%s\n' "$1" | adb shell /data/adb/ksu/bin/ksud debug su; }
fail() { echo "FAIL: $*"; exit 1; }
[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ] || fail android-not-ready
[ -f /tmp/cubs_log_reader.ko ] || fail reader-missing
rootsh 'cmp /data/local/ios/ho.payload /data/local/ios/ho.payload.prod || exit 1; for f in boot_ios smp cam snd camid camdelay noring cpu6_khz ios_start.pre-logtest; do test ! -e /data/local/ios/$f || exit 1; done; echo preflight-ok' | grep -q preflight-ok || fail preflight
adb pull /data/local/ios/ios_start.sh /tmp/logtest-launcher.sh >/dev/null || fail pull-launcher
python3 - <<'PY' || exit 1
p='/tmp/logtest-launcher.sh'
s=open(p).read()
a='exec > $L 2>&1'
assert s.count(a)==1
watchdog='''
( sleep 210
  echo "log reader test watchdog" >> $D/ios_start.log
  if [ -f $D/ios_start.pre-logtest ]; then
    cp $D/ios_start.pre-logtest $D/ios_start.logtest.tmp && chmod 755 $D/ios_start.logtest.tmp && mv -f $D/ios_start.logtest.tmp $D/ios_start.sh
  fi
  rm -f $D/boot_ios $D/smp
  sync
  reboot
) &'''
open(p,'w').write(s.replace(a,a+watchdog))
PY
adb push /tmp/cubs_log_reader.ko /data/local/tmp/cubs_log_reader.ko >/dev/null || fail push-reader
adb push /tmp/logtest-launcher.sh /data/local/tmp/logtest-launcher.sh >/dev/null || fail push-launcher
rootsh 'cp /data/local/ios/ios_start.sh /data/local/ios/ios_start.pre-logtest && cp /data/local/tmp/logtest-launcher.sh /data/local/ios/ios_start.logtest.tmp && chmod 755 /data/local/ios/ios_start.logtest.tmp && mv -f /data/local/ios/ios_start.logtest.tmp /data/local/ios/ios_start.sh && sync && echo armed' | grep -q armed || fail arm-launcher
echo 'starting one-shot production iOS'
rootsh 'sh /data/local/ios/ios_next.sh' || :
sleep 100
echo 'reading XNU without remapping the bridge'
rootsh 'insmod /data/local/tmp/cubs_log_reader.ko && head -c 50331648 /dev/cubs_log > /data/local/tmp/logtest.bin && rmmod cubs_log_reader && echo log-read-ok' || :
adb pull /data/local/tmp/logtest.bin /tmp/logtest.bin >/dev/null 2>&1 && strings -n 5 /tmp/logtest.bin | grep -a -E 'processors are running|MiniIOMobileFramebuffer: [0-9]+ frames in|net: en0' | tail -8 | cut -c1-150 || :
echo 'waiting for phone watchdog'
sleep 125
perl -e 'alarm 150; exec @ARGV' adb wait-for-device || fail reconnect
ready=0
for i in $(seq 1 60); do
  if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then ready=1; break; fi
  sleep 3
done
[ "$ready" = 1 ] || fail android-not-booted
rootsh 'cmp /data/local/ios/ho.payload /data/local/ios/ho.payload.prod && cmp /data/local/ios/ios_start.sh /data/local/ios/ios_start.pre-logtest && test ! -e /data/local/ios/boot_ios && test ! -e /data/local/ios/smp && echo recovered-ok' | grep recovered-ok || fail recovery-check
rootsh 'rm -f /data/local/ios/ios_start.pre-logtest /data/local/tmp/logtest.bin /data/local/tmp/logtest-launcher.sh; sync'
echo test-complete
