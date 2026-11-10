#!/bin/bash
export PATH=$PATH:/opt/homebrew/bin
D=/data/local/ios
ORIG=$HOME/unixnu-pixel11/hackios-upstream/xnu-src/xnu-8796.121.2/bsd/dev/redwood_battery.c
cleanup() {
  cp /tmp/redwood_battery.original.c "$ORIG"
  perl -e 'alarm 180; exec @ARGV' adb wait-for-device || return
  for i in $(seq 1 40); do [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\r")" = 1 ] && break; sleep 5; done
  adb shell "echo 'if [ -f /data/local/ios/ios_start.pre-battery ]; then cp /data/local/ios/ios_start.pre-battery /data/local/ios/ios_start.sh; chmod 755 /data/local/ios/ios_start.sh; fi; rm -f /data/local/ios/boot_ios /data/local/ios/smp /data/local/ios/cam /data/local/ios/snd /data/local/ios/camid /data/local/ios/camdelay /data/local/ios/noring /data/local/ios/cpu6_khz; cmp /data/local/ios/ho.payload /data/local/ios/ho.payload.prod && echo payload-is-prod; sync' | /data/adb/ksu/bin/ksud debug su"
}
trap cleanup EXIT
adb pull "$D/ios_start.sh" /tmp/ios_start_battery.sh >/dev/null || exit 1
python3 - <<'PY'
p='/tmp/ios_start_battery.sh'
s=open(p).read()
a='exec > $L 2>&1'
b='[ -x $D/netsrv ] && sh $D/netsrv.sh &'
assert s.count(a)==1 and s.count(b)==1
s=s.replace(a,a+'\n( sleep 420; echo "battery test watchdog reboot" >> $D/ios_start.log; sync; reboot ) &')
s=s.replace(b,b+'\n/data/local/tmp/battsrv > $D/battsrv.log 2>&1 &')
open(p,'w').write(s)
PY
[ $? -eq 0 ] || exit 1
adb push /tmp/battsrv /data/local/tmp/battsrv >/dev/null || exit 1
adb push /tmp/ios_start_battery.sh /data/local/tmp/ios_start_battery.sh >/dev/null || exit 1
adb shell "echo 'cp /data/local/ios/ios_start.sh /data/local/ios/ios_start.pre-battery; cp /data/local/tmp/ios_start_battery.sh /data/local/ios/ios_start.sh; chmod 755 /data/local/ios/ios_start.sh /data/local/tmp/battsrv; sync' | /data/adb/ksu/bin/ksud debug su"
export SHOTGRAB=1 TAILN=20 POST='tail -3 /data/local/ios/battsrv.log'
bash "$HOME/cycle.sh" cubsbatt1 '/redwood/bin/battery_test 20 10' 'cubs_battery=1 cubs_shot=1' 220 'cubs battery:|battery_test:|RedwoodBattery:'
