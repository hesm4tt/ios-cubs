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
rootsh 'cmp /data/local/ios/ho.payload /data/local/ios/ho.payload.prod || exit 1; for f in boot_ios smp cam camid camdelay noring cpu6_khz ios_start.pre-cubsvs; do test ! -e /data/local/ios/$f || exit 1; done; echo preflight-ok' | grep preflight-ok >/dev/null || fail preflight
read -r RAMOFF LISTOFF < /tmp/cubsvolsound-offsets
[ "$RAMOFF" = 28b4000 ] && [ "$LISTOFF" = 17fe00000 ] || fail offsets-changed
adb pull /data/local/ios/ios_start.sh /tmp/cubsvs-launcher.sh >/dev/null || fail pull-launcher
python3 - <<'PY' || exit 1
p='/tmp/cubsvs-launcher.sh'; s=open(p).read()
a='exec > $L 2>&1'
assert s.count(a)==1
watch='''
( echo "$(date): timer started" >> $D/cubsvs-watchdog.log
  sleep 420
  echo "$(date): watchdog fired" >> $D/cubsvs-watchdog.log
  cp $D/ho.payload.prod $D/ho.payload.cubsvs.tmp && mv -f $D/ho.payload.cubsvs.tmp $D/ho.payload
  cp $D/ios_start.pre-cubsvs $D/ios_start.cubsvs.tmp && chmod 755 $D/ios_start.cubsvs.tmp && mv -f $D/ios_start.cubsvs.tmp $D/ios_start.sh
  rm -f $D/boot_ios $D/smp $D/snd
  sync; reboot
) &'''
s=s.replace(a,a+watch)
open(p,'w').write(s)
PY
adb push "$HOME/pcwork/hopay2/cubsvolsoundr.payload" /data/local/tmp/cubsvs.payload >/dev/null || fail payload-push
adb push /tmp/cubsvs-launcher.sh /data/local/tmp/cubsvs-launcher.sh >/dev/null || fail launcher-push
rootsh 'rm -f /data/local/ios/cubsvs-watchdog.log; cp /data/local/ios/ios_start.sh /data/local/ios/ios_start.pre-cubsvs && cp /data/local/tmp/cubsvs-launcher.sh /data/local/ios/ios_start.cubsvs.tmp && chmod 755 /data/local/ios/ios_start.cubsvs.tmp && mv -f /data/local/ios/ios_start.cubsvs.tmp /data/local/ios/ios_start.sh && cp /data/local/tmp/cubsvs.payload /data/local/ios/ho.payload && touch /data/local/ios/snd && sync && echo armed' | grep armed >/dev/null || fail arm
armed=1
echo 'starting one-core wallpaper experiment'
rootsh 'sh /data/local/ios/ios_next.sh' || :
ready=0
for i in $(seq 1 150); do
  if adb shell "grep -q 'timer started' /data/local/ios/cubsvs-watchdog.log && grep -q 'XNU started' /data/local/ios/ios_start.log" 2>/dev/null; then ready=1; break; fi
  sleep 2
done
if [ "$ready" = 1 ]; then
  echo 'iOS started; collecting evidence'
  sleep 205; adb shell 'logcat -d | grep CubsSnd | tail -45 | cut -c19-100' > /tmp/vs-snd.txt 2>&1
  rootsh 'insmod /data/local/tmp/cubs_log_reader.ko && head -c 50331648 /dev/cubs_log > /data/local/tmp/cubsvs-log.bin && rmmod cubs_log_reader && echo log-read-ok' || :
  adb pull /data/local/tmp/cubsvs-log.bin /tmp/cubsvs-log.bin >/dev/null 2>&1 || :
  rootsh '/data/local/tmp/ringrd 0x1C00000 0x400000 /data/local/tmp/cubsvs-shot.bin' || :
  adb pull /data/local/tmp/cubsvs-shot.bin /tmp/cubsvs-shot.bin >/dev/null 2>&1 || :
else echo 'iOS startup not observed'; fi
echo 'restoring Android'
rootsh 'cp /data/local/ios/ho.payload.prod /data/local/ios/ho.payload.cubsvs.tmp && mv -f /data/local/ios/ho.payload.cubsvs.tmp /data/local/ios/ho.payload; cp /data/local/ios/ios_start.pre-cubsvs /data/local/ios/ios_start.cubsvs.tmp && chmod 755 /data/local/ios/ios_start.cubsvs.tmp && mv -f /data/local/ios/ios_start.cubsvs.tmp /data/local/ios/ios_start.sh; rm -f /data/local/ios/boot_ios /data/local/ios/smp /data/local/ios/snd; sync; reboot' || :
perl -e 'alarm 180; exec @ARGV' adb wait-for-device || fail reconnect
ready=0
for i in $(seq 1 70); do
  if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && adb shell '! pidof drmfb2 >/dev/null' 2>/dev/null; then ready=1; break; fi
  sleep 3
done
[ "$ready" = 1 ] || fail android-not-ready-after-reboot
rootsh 'cmp /data/local/ios/ho.payload /data/local/ios/ho.payload.prod && cmp /data/local/ios/ios_start.sh /data/local/ios/ios_start.pre-cubsvs && test ! -e /data/local/ios/boot_ios && test ! -e /data/local/ios/smp && test ! -e /data/local/ios/snd && echo recovery-verified' | grep recovery-verified || fail recovery-check
armed=0
rootsh 'rm -f /data/local/ios/ios_start.pre-cubsvs /data/local/tmp/cubsvs-log.bin /data/local/tmp/cubsvs-shot.bin /data/local/tmp/cubsvs-launcher.sh /data/local/tmp/cubsvs.payload; sync'
echo test-complete
