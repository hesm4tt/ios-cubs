#!/bin/bash
# Supervised boot of the INSTALLED production payload (no payload swap). The watchdog restores production before rebooting.
set -u
export PATH="$PATH:/opt/homebrew/bin"
rootsh() { printf '%s\n' "$1" | adb shell /data/adb/ksu/bin/ksud debug su; }
fail() { echo "FAIL: $*"; exit 1; }
armed=0
cleanup() { [ "$armed" = 0 ] || echo 'recovery unverified: watchdog may have stopped if Android rebooted'; }
trap cleanup EXIT
[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ] || fail android-not-ready
rootsh 'cmp /data/local/ios/ho.payload /data/local/ios/ho.payload.prod || exit 1; for f in boot_ios smp cam camid camdelay noring cpu6_khz ios_start.pre-cubsprodfinal; do test ! -e /data/local/ios/$f || exit 1; done; echo preflight-ok' | grep preflight-ok >/dev/null || fail preflight
adb shell cat /data/local/ios/env.sh | tr -d '
' | grep -q 'RAMOFF=28b4000' || fail offsets-changed
adb pull /data/local/ios/ios_start.sh /tmp/cubsprodfinal-launcher.sh >/dev/null || fail pull-launcher
python3 - <<'PY' || exit 1
p='/tmp/cubsprodfinal-launcher.sh'; s=open(p).read()
a='exec > $L 2>&1'
assert s.count(a)==1
watch='''
( echo "$(date): timer started" >> $D/cubsprodfinal-watchdog.log
  sleep 420
  echo "$(date): watchdog fired" >> $D/cubsprodfinal-watchdog.log
  cp $D/ho.payload.prod $D/ho.payload.cubsprodfinal.tmp && mv -f $D/ho.payload.cubsprodfinal.tmp $D/ho.payload
  cp $D/ios_start.pre-cubsprodfinal $D/ios_start.cubsprodfinal.tmp && chmod 755 $D/ios_start.cubsprodfinal.tmp && mv -f $D/ios_start.cubsprodfinal.tmp $D/ios_start.sh
  rm -f $D/boot_ios $D/smp
  sync; reboot
) &'''
s=s.replace(a,a+watch)
open(p,'w').write(s)
PY
adb push /tmp/cubsprodfinal-launcher.sh /data/local/tmp/cubsprodfinal-launcher.sh >/dev/null || fail launcher-push
rootsh 'rm -f /data/local/ios/cubsprodfinal-watchdog.log; cp /data/local/ios/ios_start.sh /data/local/ios/ios_start.pre-cubsprodfinal && cp /data/local/tmp/cubsprodfinal-launcher.sh /data/local/ios/ios_start.cubsprodfinal.tmp && chmod 755 /data/local/ios/ios_start.cubsprodfinal.tmp && mv -f /data/local/ios/ios_start.cubsprodfinal.tmp /data/local/ios/ios_start.sh && sync && echo armed' | grep armed >/dev/null || fail arm
armed=1
echo 'starting one-core wallpaper experiment'
rootsh 'sh /data/local/ios/ios_next.sh' || :
ready=0
for i in $(seq 1 150); do
  if adb shell "grep -q 'timer started' /data/local/ios/cubsprodfinal-watchdog.log && grep -q 'XNU started' /data/local/ios/ios_start.log" 2>/dev/null; then ready=1; break; fi
  sleep 2
done
if [ "$ready" = 1 ]; then
  echo 'iOS started; collecting evidence'
  sleep 170; adb shell 'logcat -d | grep CubsSnd | tail -2; tail -2 /data/local/ios/sndsrv.log' > /tmp/pf-snd.txt 2>&1
  rootsh 'insmod /data/local/tmp/cubs_log_reader.ko && head -c 50331648 /dev/cubs_log > /data/local/tmp/cubsprodfinal-log.bin && rmmod cubs_log_reader && echo log-read-ok' || :
  adb pull /data/local/tmp/cubsprodfinal-log.bin /tmp/cubsprodfinal-log.bin >/dev/null 2>&1 || :
  rootsh '/data/local/tmp/ringrd 0x1C00000 0x400000 /data/local/tmp/cubsprodfinal-shot.bin' || :
  adb pull /data/local/tmp/cubsprodfinal-shot.bin /tmp/cubsprodfinal-shot.bin >/dev/null 2>&1 || :
else echo 'iOS startup not observed'; fi
echo 'restoring Android'
rootsh 'cp /data/local/ios/ho.payload.prod /data/local/ios/ho.payload.cubsprodfinal.tmp && mv -f /data/local/ios/ho.payload.cubsprodfinal.tmp /data/local/ios/ho.payload; cp /data/local/ios/ios_start.pre-cubsprodfinal /data/local/ios/ios_start.cubsprodfinal.tmp && chmod 755 /data/local/ios/ios_start.cubsprodfinal.tmp && mv -f /data/local/ios/ios_start.cubsprodfinal.tmp /data/local/ios/ios_start.sh; rm -f /data/local/ios/boot_ios /data/local/ios/smp; sync; reboot' || :
perl -e 'alarm 180; exec @ARGV' adb wait-for-device || fail reconnect
ready=0
for i in $(seq 1 70); do
  if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && adb shell '! pidof drmfb2 >/dev/null' 2>/dev/null; then ready=1; break; fi
  sleep 3
done
[ "$ready" = 1 ] || fail android-not-ready-after-reboot
rootsh 'cmp /data/local/ios/ho.payload /data/local/ios/ho.payload.prod && cmp /data/local/ios/ios_start.sh /data/local/ios/ios_start.pre-cubsprodfinal && test ! -e /data/local/ios/boot_ios && test ! -e /data/local/ios/smp && echo recovery-verified' | grep recovery-verified || fail recovery-check
armed=0
rootsh 'rm -f /data/local/ios/ios_start.pre-cubsprodfinal /data/local/tmp/cubsprodfinal-log.bin /data/local/tmp/cubsprodfinal-shot.bin /data/local/tmp/cubsprodfinal-launcher.sh /data/local/tmp/cubsprodfinal.payload; sync'
echo test-complete
