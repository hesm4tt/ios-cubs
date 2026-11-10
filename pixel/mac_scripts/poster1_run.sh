#!/bin/bash
export PATH=$PATH:/opt/homebrew/bin
U=$HOME/unixnu-pixel11/hackios-upstream/userland
cp "$U/mkjobs.py" /tmp/mkjobs.pre-poster.py || exit 1
cleanup() {
  cp /tmp/mkjobs.pre-poster.py "$U/mkjobs.py"
  perl -e 'alarm 180; exec @ARGV' adb wait-for-device || return
  for i in $(seq 1 40); do [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\r")" = 1 ] && break; sleep 5; done
  adb shell "echo 'if [ -f /data/local/ios/ios_start.pre-poster ]; then cp /data/local/ios/ios_start.pre-poster /data/local/ios/ios_start.sh; chmod 755 /data/local/ios/ios_start.sh; fi; rm -f /data/local/ios/boot_ios /data/local/ios/smp /data/local/ios/cam /data/local/ios/snd /data/local/ios/camid /data/local/ios/camdelay /data/local/ios/noring /data/local/ios/cpu6_khz; cmp /data/local/ios/ho.payload /data/local/ios/ho.payload.prod && echo payload-is-prod; sync' | /data/adb/ksu/bin/ksud debug su"
}
trap cleanup EXIT
python3 /tmp/patch_posterboard.py "$U/mkjobs.py" || exit 1
adb pull /data/local/ios/ios_start.sh /tmp/ios_start_poster.sh >/dev/null || exit 1
python3 - <<'PY'
p='/tmp/ios_start_poster.sh'; s=open(p).read(); a='exec > $L 2>&1'; assert s.count(a)==1
s=s.replace(a,a+'\n( sleep 450; echo "poster test watchdog reboot" >> $D/ios_start.log; sync; reboot ) &')
open(p,'w').write(s)
PY
[ $? -eq 0 ] || exit 1
adb push /tmp/ios_start_poster.sh /data/local/tmp/ios_start_poster.sh >/dev/null || exit 1
adb shell "echo 'cp /data/local/ios/ios_start.sh /data/local/ios/ios_start.pre-poster; cp /data/local/tmp/ios_start_poster.sh /data/local/ios/ios_start.sh; chmod 755 /data/local/ios/ios_start.sh; sync' | /data/adb/ksu/bin/ksud debug su"
export IOS_EXTRA='com.apple.configd com.apple.mDNSResponder com.apple.mDNSResponderHelper com.apple.trustd com.apple.mediaserverd com.apple.nanoregistryd com.apple.nanoregistrylaunchd com.apple.PosterBoard'
export SHOTGRAB=1 TAILN=20 OSLOG='com.apple.PosterBoard'
export POST='tail -3 /data/local/ios/battsrv.log; tail -2 /data/local/ios/netsrv.log'
bash "$HOME/cycle.sh" poster1 '/redwood/bin/net_test wait 100 show dhcp en0 waitaddr en0 60 resolve example.com fetch https://example.com/;/redwood/bin/rwtouch wait 5 swipe 0.5 0.985 0.5 0.3 250 wait 8;/redwood/bin/battery_test 1' 'cubs_shot=1' 270 'posterboard|PosterBoard|wallpaper|net_test:|cubs battery:'
