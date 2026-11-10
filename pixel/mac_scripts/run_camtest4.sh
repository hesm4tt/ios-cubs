#!/bin/bash
# Supervised, one-core test. The watchdog restores production before rebooting.
set -u
export PATH="$PATH:/opt/homebrew/bin"
rootsh() { printf '%s\n' "$1" | adb shell /data/adb/ksu/bin/ksud debug su; }
fail() { echo "FAIL: $*"; exit 1; }
armed=0
cleanup() { [ "$armed" = 0 ] || echo 'recovery unverified: watchdog may have stopped if Android rebooted'; }
trap cleanup EXIT
[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ] || fail android-not-ready
rootsh 'cmp /data/local/ios/ho.payload /data/local/ios/ho.payload.prod || exit 1; for f in boot_ios smp cam camid camdelay noring cpu6_khz ios_start.pre-cubscm; do test ! -e /data/local/ios/$f || exit 1; done; echo preflight-ok' | grep preflight-ok >/dev/null || fail preflight
read -r RAMOFF LISTOFF < /tmp/cubscamtest-offsets
[ "$RAMOFF" = 28b4000 ] && [ "$LISTOFF" = 17fe00000 ] || fail offsets-changed
adb pull /data/local/ios/ios_start.sh /tmp/cubscm-launcher.sh >/dev/null || fail pull-launcher
python3 - <<'PY' || exit 1
p='/tmp/cubscm-launcher.sh'; s=open(p).read()
a='exec > $L 2>&1'
assert s.count(a)==1
watch='''
( echo "$(date): timer started" >> $D/cubscm-watchdog.log
  sleep 420
  echo "$(date): watchdog fired" >> $D/cubscm-watchdog.log
  cp $D/ho.payload.prod $D/ho.payload.cubscm.tmp && mv -f $D/ho.payload.cubscm.tmp $D/ho.payload
  cp $D/ios_start.pre-cubscm $D/ios_start.cubscm.tmp && chmod 755 $D/ios_start.cubscm.tmp && mv -f $D/ios_start.cubscm.tmp $D/ios_start.sh
  rm -f $D/boot_ios $D/smp $D/cam $D/camid
  sync; reboot
) &'''
s=s.replace(a,a+watch).replace('CAMSRV_RING=1 CAMSRV_SAVE=0','CAMSRV_RING=1 CAMSRV_RING_AFTER=400 CAMSRV_SAVE=0')
open(p,'w').write(s)
PY
adb push "$HOME/pcwork/hopay2/cubscamtestr.payload" /data/local/tmp/cubscm.payload >/dev/null || fail payload-push
adb push /tmp/cubscm-launcher.sh /data/local/tmp/cubscm-launcher.sh >/dev/null || fail launcher-push
rootsh 'rm -f /data/local/ios/cubscm-watchdog.log; cp /data/local/ios/ios_start.sh /data/local/ios/ios_start.pre-cubscm && cp /data/local/tmp/cubscm-launcher.sh /data/local/ios/ios_start.cubscm.tmp && chmod 755 /data/local/ios/ios_start.cubscm.tmp && mv -f /data/local/ios/ios_start.cubscm.tmp /data/local/ios/ios_start.sh && cp /data/local/tmp/cubscm.payload /data/local/ios/ho.payload && touch /data/local/ios/cam && echo 1 > /data/local/ios/camid && sync && echo armed' | grep armed >/dev/null || fail arm
armed=1
echo 'starting one-core wallpaper experiment'
rootsh 'sh /data/local/ios/ios_next.sh' || :
ready=0
for i in $(seq 1 150); do
  if adb shell "grep -q 'timer started' /data/local/ios/cubscm-watchdog.log && grep -q 'XNU started' /data/local/ios/ios_start.log" 2>/dev/null; then ready=1; break; fi
  sleep 2
done
if [ "$ready" = 1 ]; then
  echo 'iOS started; collecting evidence'
  sleep 100
  adb shell 'cat /sys/devices/system/cpu/online /sys/devices/system/cpu/offline; for z in /sys/class/thermal/thermal_zone*; do echo $(cat $z/type) $(cat $z/temp); done' > /tmp/cd-state.txt 2>&1
  adb logcat -d -v time > /tmp/cd-logcat.txt 2>&1
  adb shell 'cat /proc/uptime; dmesg' > /tmp/cd-dmesg-full.txt 2>&1
  adb shell 'grep -a "XNU started" /data/local/ios/ios_start.log; date' >> /tmp/cd-dmesg-full.txt 2>&1
  rootsh 'insmod /data/local/tmp/cubs_log_reader.ko && head -c 50331648 /dev/cubs_log > /data/local/tmp/cubscd-log.bin && rmmod cubs_log_reader && echo log-read-ok' || :
  adb pull /data/local/tmp/cubscd-log.bin /tmp/cubscd-log.bin >/dev/null 2>&1 || :
  rootsh '/data/local/tmp/ringrd 0x1C00000 0x400000 /data/local/tmp/cubscd-shot.bin' || :
  adb pull /data/local/tmp/cubscd-shot.bin /tmp/cubscd-shot.bin >/dev/null 2>&1 || :
else echo 'iOS startup not observed'; fi
echo 'restoring Android'
rootsh 'cp /data/local/ios/ho.payload.prod /data/local/ios/ho.payload.cubscm.tmp && mv -f /data/local/ios/ho.payload.cubscm.tmp /data/local/ios/ho.payload; cp /data/local/ios/ios_start.pre-cubscm /data/local/ios/ios_start.cubscm.tmp && chmod 755 /data/local/ios/ios_start.cubscm.tmp && mv -f /data/local/ios/ios_start.cubscm.tmp /data/local/ios/ios_start.sh; rm -f /data/local/ios/boot_ios /data/local/ios/smp /data/local/ios/cam /data/local/ios/camid; sync; reboot' || :
perl -e 'alarm 180; exec @ARGV' adb wait-for-device || fail reconnect
ready=0
for i in $(seq 1 70); do
  if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && adb shell '! pidof drmfb2 >/dev/null' 2>/dev/null; then ready=1; break; fi
  sleep 3
done
[ "$ready" = 1 ] || fail android-not-ready-after-reboot
rootsh 'cmp /data/local/ios/ho.payload /data/local/ios/ho.payload.prod && cmp /data/local/ios/ios_start.sh /data/local/ios/ios_start.pre-cubscm && test ! -e /data/local/ios/boot_ios && test ! -e /data/local/ios/smp && test ! -e /data/local/ios/cam && echo recovery-verified' | grep recovery-verified || fail recovery-check
armed=0
rootsh 'rm -f /data/local/ios/ios_start.pre-cubscm /data/local/tmp/cubscd-log.bin /data/local/tmp/cubscd-shot.bin /data/local/tmp/cubscm-launcher.sh /data/local/tmp/cubscm.payload; sync'
echo test-complete
