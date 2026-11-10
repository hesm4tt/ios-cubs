#!/bin/bash
export PATH=$PATH:/opt/homebrew/bin
D=$HOME/unixnu-pixel11/hackios-upstream/xnu-src/xnu-8796.121.2/bsd/dev
cleanup() {
  cp /tmp/redwood_cubs_net.pre-wifi.c "$D/redwood_cubs_net.c"
  cp /tmp/redwood_apple80211.pre-wifi.c "$D/redwood_apple80211.c"
  perl -e 'alarm 180; exec @ARGV' adb wait-for-device || return
  for i in $(seq 1 40); do [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\r")" = 1 ] && break; sleep 5; done
  adb shell "echo 'if [ -f /data/local/ios/ios_start.pre-wifistatus ]; then cp /data/local/ios/ios_start.pre-wifistatus /data/local/ios/ios_start.sh; chmod 755 /data/local/ios/ios_start.sh; fi; rm -f /data/local/ios/boot_ios /data/local/ios/smp /data/local/ios/cam /data/local/ios/snd /data/local/ios/camid /data/local/ios/camdelay /data/local/ios/noring /data/local/ios/cpu6_khz; cmp /data/local/ios/ho.payload /data/local/ios/ho.payload.prod && echo payload-is-prod; sync' | /data/adb/ksu/bin/ksud debug su"
}
trap cleanup EXIT
python3 - <<'PY'
import struct
p='$HOME/hopay/wifibuild2.payload'; d=open(p,'rb').read(80)
vb,_,_,_,ke,_,mem=struct.unpack_from('<7Q',d,16)
assert ke-vb-((2492203008+0x3fff)&~0x3fff)==0x28b8000 and mem-0x100000==0x17fe00000
print('experimental RAM offsets checked')
PY
[ $? -eq 0 ] || exit 1
adb pull /data/local/ios/ios_start.sh /tmp/ios_start_wifistatus.sh >/dev/null || exit 1
python3 - <<'PY'
p='/tmp/ios_start_wifistatus.sh';s=open(p).read();a='exec > $L 2>&1';b='. $D/env.sh';c='[ -x $D/netsrv ] && sh $D/netsrv.sh &'
assert s.count(a)==1 and s.count(b)==1 and s.count(c)==1
s=s.replace(a,a+'''\n( sleep 420
  echo "$(date): watchdog fired" >> $D/watchdog.log
  ( cp $D/ho.payload.prod $D/ho.payload.watchdog.tmp && mv -f $D/ho.payload.watchdog.tmp $D/ho.payload ) && echo "$(date): payload restored" >> $D/watchdog.log || echo "$(date): payload restore failed" >> $D/watchdog.log
  if [ -f $D/ios_start.pre-wifistatus ]; then
    ( cp $D/ios_start.pre-wifistatus $D/ios_start.watchdog.tmp && chmod 755 $D/ios_start.watchdog.tmp && mv -f $D/ios_start.watchdog.tmp $D/ios_start.sh ) && echo "$(date): launcher restored" >> $D/watchdog.log || echo "$(date): launcher restore failed" >> $D/watchdog.log
  fi
  rm -f $D/boot_ios $D/smp $D/cam $D/snd $D/camid $D/camdelay $D/noring $D/cpu6_khz
  echo "$(date): requesting reboot" >> $D/watchdog.log
  sync
  reboot
) &''')
s=s.replace(b,b+'\nRAMOFF=28b8000')
assert s.count('[ -f $D/smp ] && echo 0 > /sys/devices/system/cpu/cpu5/online') == 1
s=s.replace('[ -f $D/smp ] && echo 0 > /sys/devices/system/cpu/cpu5/online', '''if [ -f $D/smp ]; then
    echo 0 > /sys/devices/system/cpu/cpu4/online
    if [ "$(cat /sys/devices/system/cpu/cpu4/online)" != 0 ]; then echo 'CPU4 offline failed'; exit 1; fi
fi
[ -f $D/smp ] && echo 0 > /sys/devices/system/cpu/cpu5/online''')
s=s.replace(c,c+'\n/data/local/tmp/wifisrv "$WIFI_APP_UID" > $D/wifisrv.log 2>&1 &')
s=s.replace('stop surfaceflinger; stop vendor.hwcomposer-3; sleep 2', '''WIFI_APP_UID=$(cmd package list packages -U com.cubs.cam | sed -n 's/.*uid://p' | tr -d '\\r')
case "$WIFI_APP_UID" in ''|*[!0-9]*) echo 'wifi app uid unavailable'; exit 1;; esac
am start-foreground-service --user 0 -n com.cubs.cam/com.cubs.cam.WifiStatusService > $D/wifiapp.log 2>&1
sleep 2
stop surfaceflinger; stop vendor.hwcomposer-3; sleep 2''')
open(p,'w').write(s)
PY
[ $? -eq 0 ] || exit 1
adb push /tmp/wifisrv /data/local/tmp/wifisrv >/dev/null || exit 1
adb push /tmp/ios_start_wifistatus.sh /data/local/tmp/ios_start_wifistatus.sh >/dev/null || exit 1
adb shell "echo 'cp /data/local/ios/ios_start.sh /data/local/ios/ios_start.pre-wifistatus; cp /data/local/tmp/ios_start_wifistatus.sh /data/local/ios/ios_start.sh; chmod 755 /data/local/ios/ios_start.sh /data/local/tmp/wifisrv; sync' | /data/adb/ksu/bin/ksud debug su"
export IOS_EXTRA='com.apple.configd com.apple.mDNSResponder com.apple.mDNSResponderHelper com.apple.trustd com.apple.mediaserverd com.apple.nanoregistryd com.apple.nanoregistrylaunchd com.apple.PosterBoard com.apple.wifid'
export SHOTGRAB=1 TAILN=30
export SMP=1 CPUS=3 ADT=/tmp/ho_three_experiment.adt
export POST='tail -3 /data/local/ios/wifisrv.log; grep "rule:" /data/local/ios/netsrv.log | tail -2'
bash "$HOME/cycle.sh" wifistatus3 '/redwood/bin/sound_test springboard;/redwood/bin/battery_test open prefs:root=WIFI;/redwood/bin/rwtouch wait 60;/redwood/bin/net_test show dhcp en0 waitaddr en0 30 resolve example.com fetch https://example.com/' 'cubs_wifi=1 cubs_shot=1' 250 'cubs wifi:|wifid|apple80211|net_test:|wifi:|net: en0|processors are running'
