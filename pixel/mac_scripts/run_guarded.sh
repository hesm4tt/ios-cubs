#!/bin/bash
# run_guarded.sh: one supervised iOS test run on the Pixel (runs on the Mac, phone on USB). The phone ALWAYS ends in Android:
# a phone-side 420 s watchdog restores production and reboots, and this script restores + verifies the same on the normal path.
#
#   NAME=cubsfoo [options] bash run_guarded.sh
#
#   NAME          payload base name: ~/pcwork/hopay2/${NAME}r.payload and /tmp/${NAME}-offsets (from build_wallpaper_normal_payload.sh)
#   ARM           root shell commands that arm test flags on the phone (default none), e.g. 'touch /data/local/ios/cam; echo 1 > /data/local/ios/camid'
#   DISARM        root shell commands that undo ARM (run on every exit path, also by the phone watchdog)
#   LAUNCHER_EXTRA  extra lines put at the top of the phone launcher (phone-side loops that must not depend on adb)
#   JB_OK         1 = keep the production `jb` flag (payload has the big RAM-disk reserve); default: the flag is removed for the run and put back
#   LOOP          1 (default): phone-side loop saving kernel screenshots (/data/local/tmp/cvN.bin) and the heartbeat page (hb.log)
#   LOOP_START    seconds after launcher start before the screenshot burst starts (default 100)
#   WAIT          seconds after "XNU started" before collecting evidence (default 170)
#   OUT           output directory on the Mac (default /tmp/guarded-$NAME)
#   COOL          battery temp (tenths of C) to wait below before starting (default 370)
#   LAUNCHER_SED  a sed expression applied to the phone launcher copy (e.g. to use another system image file)
#   LAUNCHER_PATCH a python script applied to the phone launcher copy (e.g. wifi_launcher_patch.py)
#   PUSH          "local:remote" file pushed to the phone before arming and removed at the end (e.g. a big alternate system image)
#   EVIDENCE      extra Mac-side bash run after WAIT (adb works; write into $OUT)
#
# Traps this script handles: RAMOFF of the test payload is taken from its offsets file (production env.sh keeps its own);
# stale ios_start.log/hb.log are removed when arming; the preflight refuses leftovers; never edit this file while it runs.
set -u
export PATH="$PATH:/opt/homebrew/bin"
: "${NAME:?NAME required}"
ARM="${ARM:-:}"; DISARM="${DISARM:-:}"; LAUNCHER_EXTRA="${LAUNCHER_EXTRA:-}"; LOOP="${LOOP:-1}"; WAIT="${WAIT:-170}"
OUT="${OUT:-/tmp/guarded-$NAME}"; COOL="${COOL:-370}"; EVIDENCE="${EVIDENCE:-:}"; LOOP_START="${LOOP_START:-100}"; LAUNCHER_SED="${LAUNCHER_SED:-}"; PUSH="${PUSH:-}"
export RAMOFF_T LISTOFF_T LAUNCHER_EXTRA LOOP LOOP_START
rootsh() { printf '%s\n' "$1" | adb shell /data/adb/ksu/bin/ksud debug su; }
fail() { echo "FAIL: $*"; exit 1; }
armed=0
cleanup() { [ "$armed" = 0 ] || echo 'recovery unverified: the phone watchdog restores production at 420 s'; }
trap cleanup EXIT
mkdir -p "$OUT"; rm -f "$OUT"/cv*.bin
P="$HOME/pcwork/hopay2/${NAME}r.payload"
[ -f "$P" ] || fail "no payload $P"
read -r RAMOFF_T LISTOFF_T < "/tmp/${NAME}-offsets" || fail "no offsets file"
[ "$LISTOFF_T" = 17fe00000 ] || fail "unexpected LISTOFF $LISTOFF_T"
# wait for the battery to cool
for i in $(seq 1 120); do
  t=$(adb shell cat /sys/class/power_supply/battery/temp 2>/dev/null | tr -d '\r'); [ -n "$t" ] && [ "$t" -lt "$COOL" ] 2>/dev/null && break; sleep 30
done
[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ] || fail android-not-ready
# the production `jb` flag makes the launcher load the big system-jb.img: a payload with the small default RAM-disk reserve must not see it
# (JB_OK=1 keeps it for payloads built with build_big_payload.sh)
if [ "${JB_OK:-0}" != 1 ] && [ "$(adb shell 'test -e /data/local/ios/jb && echo 1' | tr -d '\r')" = 1 ]; then
  ARM="$ARM; rm -f /data/local/ios/jb"; DISARM="$DISARM; touch /data/local/ios/jb"
fi
rootsh 'D=/data/local/ios; cmp $D/ho.payload $D/ho.payload.prod || exit 1; for f in boot_ios smp noring cpu6_khz ios_start.pre-guarded; do test ! -e $D/$f || exit 1; done; echo preflight-ok' | grep preflight-ok >/dev/null || fail preflight
adb pull /data/local/ios/ios_start.sh "$OUT/launcher.orig" >/dev/null || fail pull-launcher
cat > "$OUT/patch.py" <<'PY'
import os,sys
s=open(sys.argv[1]).read(); a='exec > $L 2>&1'
assert s.count(a)==1 and s.count('. $D/env.sh')==1
disarm=os.environ.get('DISARM_T','')
watch='''
( echo "$(date): timer started" >> $D/guarded-watchdog.log
  sleep '''+os.environ.get('WDOG','420')+'''
  echo "$(date): watchdog fired" >> $D/guarded-watchdog.log
  cp $D/ho.payload.prod $D/ho.payload.g.tmp && mv -f $D/ho.payload.g.tmp $D/ho.payload
  cp $D/ios_start.pre-guarded $D/ios_start.g.tmp && chmod 755 $D/ios_start.g.tmp && mv -f $D/ios_start.g.tmp $D/ios_start.sh
  rm -f $D/boot_ios $D/smp
  '''+disarm+'''
  sync; reboot
) &'''
loop=''
if os.environ.get('LOOP')=='1':
    loop='\n( sleep '+os.environ.get('LOOP_START','100')+'; for i in $(seq 1 '+os.environ.get('LOOP_N','60')+'); do /data/local/tmp/ringrd 0x1C00000 0x400000 /data/local/tmp/cv$i.bin >/dev/null 2>&1; /data/local/tmp/ringrd 0xFF2000 0x30 /data/local/tmp/hb.bin >/dev/null 2>&1; echo $(date +%T) $(od -An -tx4 /data/local/tmp/hb.bin) >> $D/hb.log; sleep 3; done ) &'
s=s.replace('. $D/env.sh','. $D/env.sh; export RAMOFF='+os.environ['RAMOFF_T'])
s=s.replace(a,a+watch+loop+'\n'+os.environ.get('LAUNCHER_EXTRA',''))
open(sys.argv[1],'w').write(s)
PY
cp "$OUT/launcher.orig" "$OUT/launcher.new"
DISARM_T="$DISARM" python3 "$OUT/patch.py" "$OUT/launcher.new" || fail patch
[ -z "$LAUNCHER_SED" ] || sed -i "" "$LAUNCHER_SED" "$OUT/launcher.new" || fail launcher-sed
[ -z "${LAUNCHER_PATCH:-}" ] || python3 "$LAUNCHER_PATCH" "$OUT/launcher.new" || fail launcher-patch
[ -z "$PUSH" ] || { adb push "${PUSH%%:*}" "${PUSH#*:}" >/dev/null || fail extra-push; }
adb push "$P" /data/local/tmp/guarded.payload >/dev/null || fail payload-push
adb push "$OUT/launcher.new" /data/local/tmp/guarded-launcher.sh >/dev/null || fail launcher-push
rootsh "D=/data/local/ios; rm -f \$D/guarded-watchdog.log \$D/ios_start.log \$D/hb.log /data/local/tmp/cv*.bin; cp \$D/ios_start.sh \$D/ios_start.pre-guarded && cp /data/local/tmp/guarded-launcher.sh \$D/ios_start.g.tmp && chmod 755 \$D/ios_start.g.tmp && mv -f \$D/ios_start.g.tmp \$D/ios_start.sh && cp /data/local/tmp/guarded.payload \$D/ho.payload && $ARM; sync && echo armed" | grep armed >/dev/null || fail arm
armed=1
echo "starting $NAME (RAMOFF $RAMOFF_T)"
rootsh 'sh /data/local/ios/ios_next.sh' || :
ready=0
for i in $(seq 1 150); do
  if adb shell "grep -q 'timer started' /data/local/ios/guarded-watchdog.log && grep -q 'XNU started' /data/local/ios/ios_start.log" 2>/dev/null; then ready=1; break; fi
  sleep 2
done
if [ "$ready" = 1 ]; then
  echo 'iOS started; waiting'
  sleep "$WAIT"
  adb shell 'cat /data/local/ios/hb.log' > "$OUT/hb.txt" 2>&1
  eval "$EVIDENCE"
  adb logcat -d -v time > "$OUT/logcat.txt" 2>&1
  adb shell 'cat /proc/uptime; dmesg; grep -a "XNU started" /data/local/ios/ios_start.log; date' > "$OUT/dmesg.txt" 2>&1
  rootsh 'insmod /data/local/tmp/cubs_log_reader.ko && head -c 50331648 /dev/cubs_log > /data/local/tmp/g-log.bin && rmmod cubs_log_reader && echo log-read-ok' || :
  adb pull /data/local/tmp/g-log.bin "$OUT/kernel-log.bin" >/dev/null 2>&1 || :
  rootsh '/data/local/tmp/ringrd 0x1C00000 0x400000 /data/local/tmp/g-shot.bin' || :
  adb pull /data/local/tmp/g-shot.bin "$OUT/shot-last.bin" >/dev/null 2>&1 || :
  [ "$LOOP" = 1 ] && for i in $(seq 1 ${LOOP_N:-60}); do adb pull /data/local/tmp/cv$i.bin "$OUT/cv$i.bin" >/dev/null 2>&1 || :; done
else echo 'iOS startup not observed'; fi
echo 'restoring Android'
rootsh "D=/data/local/ios; cp \$D/ho.payload.prod \$D/ho.payload.g.tmp && mv -f \$D/ho.payload.g.tmp \$D/ho.payload; cp \$D/ios_start.pre-guarded \$D/ios_start.g.tmp && chmod 755 \$D/ios_start.g.tmp && mv -f \$D/ios_start.g.tmp \$D/ios_start.sh; rm -f \$D/boot_ios \$D/smp; $DISARM; sync; reboot" || :
perl -e 'alarm 240; exec @ARGV' adb wait-for-device || { echo "no adb 4 min after reboot: USB-lost protocol (ping the user, keep Mac-only work going)"; exit 2; }
ready=0
for i in $(seq 1 70); do
  if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && adb shell '! pidof drmfb2 >/dev/null' 2>/dev/null; then ready=1; break; fi
  sleep 3
done
[ "$ready" = 1 ] || fail android-not-ready-after-reboot
rootsh 'D=/data/local/ios; cmp $D/ho.payload $D/ho.payload.prod && cmp $D/ios_start.sh $D/ios_start.pre-guarded && test ! -e $D/boot_ios && test ! -e $D/smp && echo recovery-verified' | grep recovery-verified || fail recovery-check
armed=0
rootsh 'rm -f ${PUSH#*:} /data/local/ios/ios_start.pre-guarded /data/local/tmp/g-log.bin /data/local/tmp/g-shot.bin /data/local/tmp/guarded-launcher.sh /data/local/tmp/guarded.payload /data/local/tmp/cv*.bin; sync'
echo test-complete
