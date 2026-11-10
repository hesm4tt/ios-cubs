#!/bin/bash
export PATH=$PATH:/opt/homebrew/bin
adb push "$HOME/glsrv" /data/local/tmp/glsrv-pipeline >/dev/null || exit 1
adb shell "echo 'cp /data/local/ios/glsrv /data/local/ios/glsrv.pre-pipeline; cp /data/local/tmp/glsrv-pipeline /data/local/ios/glsrv; chmod 755 /data/local/ios/glsrv; sync' | /data/adb/ksu/bin/ksud debug su"
export SHOTGRAB=1 TAILN=30
bash "$HOME/cycle.sh" gpu_pipeline1 "$(cat "$HOME/jobs_perf3.txt")" 'cubs_shot=1' 330 'IOMFB|redwood-gl:|CUBS blit:|CUBS shot:'
adb wait-for-device
for i in $(seq 1 60); do [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\r")" = 1 ] && break; sleep 5; done
adb shell "echo 'cp /data/local/ios/glsrv.pre-pipeline /data/local/ios/glsrv; rm -f /data/local/ios/boot_ios /data/local/ios/snd /data/local/ios/cam /data/local/ios/camid /data/local/ios/camdelay /data/local/ios/noring /data/local/ios/smp /data/local/ios/cpu6_khz; cmp /data/local/ios/ho.payload /data/local/ios/ho.payload.prod && echo payload-is-prod; sync' | /data/adb/ksu/bin/ksud debug su"
