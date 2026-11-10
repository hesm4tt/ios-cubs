#!/bin/bash
# usage: jumptest.sh <cmd letter> [payload file in ~/hopay]
export PATH=$PATH:/opt/homebrew/bin
PL=${2:-ho.payload}
adb push ~/handover/cubs_stage.ko /data/local/tmp/ >/dev/null
adb push ~/hopay/$PL /data/local/tmp/ho.payload >/dev/null
printf "rm -f /dev/cubs_stage /dev/cubs_go; rmmod cubs_stage 2>/dev/null; insmod /data/local/tmp/cubs_stage.ko; sleep 2; cat /data/local/tmp/ho.payload > /dev/cubs_stage; taskset 1 sh -c \"echo S > /dev/cubs_go\"; for c in 1 2 3 4 5 6; do echo 0 > /sys/devices/system/cpu/cpu\$c/online; done; sync; echo JUMPING_$1; taskset 1 sh -c \"echo $1 > /dev/cubs_go\"\n" | adb shell "/data/adb/ksu/bin/ksud debug su" | tail -1
for i in $(seq 1 70); do sleep 5; adb devices | grep -q "device$" && break; done
sleep 25
printf "grep -a \"Reboot reason\" /sys/fs/pstore/console-ramoops-0 | tail -2\n" | adb shell "/data/adb/ksu/bin/ksud debug su" | tail -2
