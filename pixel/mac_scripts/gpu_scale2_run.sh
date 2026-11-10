#!/bin/bash
export PATH=$PATH:/opt/homebrew/bin SHOTGRAB=1 TAILN=20
bash "$HOME/cycle.sh" gpu_scale2 "$(cat "$HOME/jobs_perf3.txt")" 'fbscale=2 cubs_shot=1' 330 'MiniIOMobileFramebuffer: display|MiniIOMobileFramebuffer: [0-9]+ frames in|CUBS shot:'
adb wait-for-device
for i in $(seq 1 60); do [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\r")" = 1 ] && break; sleep 5; done
adb shell "echo 'rm -f /data/local/ios/boot_ios /data/local/ios/snd /data/local/ios/cam /data/local/ios/camid /data/local/ios/camdelay /data/local/ios/noring /data/local/ios/smp /data/local/ios/cpu6_khz; cmp /data/local/ios/ho.payload /data/local/ios/ho.payload.prod && echo payload-is-prod; sync' | /data/adb/ksu/bin/ksud debug su"
