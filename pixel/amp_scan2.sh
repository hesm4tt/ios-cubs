#!/bin/bash
export PATH=$PATH:/opt/homebrew/bin
cd ~/pcwork
wait_up() { for i in $(seq 1 60); do s=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\r"); [ "$s" = 1 ] && return; sleep 5; done; }
wait_up
adb push amp_one.sh /data/local/tmp/ >/dev/null; adb push hopay2/big2r.payload /data/local/tmp/ho.payload >/dev/null; adb push handover/cubs_stage.ko /data/local/tmp/ >/dev/null; adb shell sync
for CP in "$@"; do
  out=$(printf "CP=$CP sh /data/local/tmp/amp_one.sh 2>&1\n" | adb shell /data/adb/ksu/bin/ksud debug su 2>&1 | grep -a RESULT)
  echo "$out"
  case "$out" in *"aff=1"*) ;; *) echo "  (not reached: rebooting)"; adb reboot; sleep 30; wait_up;; esac
done
echo SCAN-DONE
