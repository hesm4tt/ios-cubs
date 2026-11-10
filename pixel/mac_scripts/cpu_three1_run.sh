#!/bin/bash
export PATH=$PATH:/opt/homebrew/bin
adb pull /data/local/ios/ios_start.sh /tmp/ios_start_three.sh >/dev/null || exit 1
python3 - <<'PY'
p='/tmp/ios_start_three.sh'
s=open(p).read()
needle='[ -f $D/smp ] && echo 0 > /sys/devices/system/cpu/cpu5/online'
assert s.count(needle)==1
s=s.replace(needle, '''if [ -f $D/smp ]; then
    echo 0 > /sys/devices/system/cpu/cpu4/online
    if [ "$(cat /sys/devices/system/cpu/cpu4/online)" != 0 ]; then
        echo "CPU4 offline failed; aborting iOS" >> "$D/ios_start.log"
        exit 1
    fi
fi
''' + needle)
open(p,'w').write(s)
PY
[ $? -eq 0 ] || exit 1
adb push /tmp/ios_start_three.sh /data/local/tmp/ios_start_three.sh >/dev/null || exit 1
adb shell "echo 'cp /data/local/ios/ios_start.sh /data/local/ios/ios_start.pre-three; cp /data/local/tmp/ios_start_three.sh /data/local/ios/ios_start.sh; chmod 755 /data/local/ios/ios_start.sh; sync' | /data/adb/ksu/bin/ksud debug su"
export SMP=1 CPUS=3 ADT=/tmp/ho_three_experiment.adt TAILN=25
bash "$HOME/cycle.sh" cpu_three1 "$(cat "$HOME/jobs_perf3.txt")" '' 330 'processors are running|psci:|MiniIOMobileFramebuffer:.*frames in|CUBS blit: processors|panic'
adb wait-for-device
for i in $(seq 1 60); do [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\r")" = 1 ] && break; sleep 5; done
adb shell "echo 'cp /data/local/ios/ios_start.pre-three /data/local/ios/ios_start.sh; chmod 755 /data/local/ios/ios_start.sh; rm -f /data/local/ios/boot_ios /data/local/ios/snd /data/local/ios/cam /data/local/ios/camid /data/local/ios/camdelay /data/local/ios/noring /data/local/ios/smp /data/local/ios/cpu6_khz; cmp /data/local/ios/ho.payload /data/local/ios/ho.payload.prod && echo payload-is-prod; sync' | /data/adb/ksu/bin/ksud debug su"
