#!/bin/bash
export PATH=$PATH:/opt/homebrew/bin
cleanup() {
  perl -e 'alarm 180; exec @ARGV' adb wait-for-device || return
  for i in $(seq 1 40); do [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\r")" = 1 ] && break; sleep 5; done
  adb shell "echo 'if [ -f /data/local/ios/ios_start.pre-wifi ]; then cp /data/local/ios/ios_start.pre-wifi /data/local/ios/ios_start.sh; chmod 755 /data/local/ios/ios_start.sh; fi; rm -f /data/local/ios/boot_ios /data/local/ios/smp /data/local/ios/cam /data/local/ios/snd /data/local/ios/camid /data/local/ios/camdelay /data/local/ios/noring /data/local/ios/cpu6_khz; cmp /data/local/ios/ho.payload /data/local/ios/ho.payload.prod && echo payload-is-prod; sync' | /data/adb/ksu/bin/ksud debug su"
}
trap cleanup EXIT
adb pull /data/local/ios/ios_start.sh /tmp/ios_start_wifi.sh >/dev/null || exit 1
python3 - <<'PY'
p='/tmp/ios_start_wifi.sh';s=open(p).read();a='exec > $L 2>&1';assert s.count(a)==1
s=s.replace(a,a+'\n( sleep 400; echo "wifi test watchdog reboot" >> $D/ios_start.log; sync; reboot ) &')
open(p,'w').write(s)
PY
[ $? -eq 0 ] || exit 1
adb push /tmp/ios_start_wifi.sh /data/local/tmp/ios_start_wifi.sh >/dev/null || exit 1
adb shell "echo 'cp /data/local/ios/ios_start.sh /data/local/ios/ios_start.pre-wifi; cp /data/local/tmp/ios_start_wifi.sh /data/local/ios/ios_start.sh; chmod 755 /data/local/ios/ios_start.sh; sync' | /data/adb/ksu/bin/ksud debug su"
export TAILN=15
export POST='grep "rule:" /data/local/ios/netsrv.log | tail -3; tail -1 /data/local/ios/battsrv.log'
bash "$HOME/cycle.sh" wifi1 '/redwood/bin/net_test wait 80 show dhcp en0 waitaddr en0 30 resolve example.com fetch https://example.com/;/redwood/bin/battery_test 1' '' 220 'net_test:|cubs battery:|battery_test:'
