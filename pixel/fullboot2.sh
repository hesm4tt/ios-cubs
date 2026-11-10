#!/bin/bash
# usage: fullboot2.sh <payload file in ~/hopay>  (stage + load iOS root from modem_a/b + jump); waits for return
export PATH=$PATH:/opt/homebrew/bin
PL=${1:-hofull.payload}
adb push ~/handover/cubs_stage.ko /data/local/tmp/ >/dev/null
adb push ~/hopay/$PL /data/local/tmp/ho.payload >/dev/null
adb push /tmp/fb_dev.sh /data/local/tmp/ >/dev/null 2>&1
adb shell "/data/adb/ksu/bin/ksud debug su" <<< "sh /data/local/tmp/fb_dev.sh" | tail -3
for i in $(seq 1 60); do sleep 5; adb devices | grep -q "device$" && adb shell echo ok 2>/dev/null | grep -q ok && break; done
sleep 20
printf "grep -a \"Reboot reason\" /sys/fs/pstore/console-ramoops-0 | tail -2\n" | adb shell "/data/adb/ksu/bin/ksud debug su" | tail -2
