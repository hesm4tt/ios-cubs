#!/bin/bash
# One supervised boot of the Wi-Fi status/scan bridge test payload (cubswifit): flag `wifi` armed for the run only, launcher patched in the
# runner's copy, evidence in /tmp/g-wifi (kernel-log.bin, cv*.bin screenshots, logcat.txt, wifi daemon logs).
set -u
export PATH="$PATH:/opt/homebrew/bin"
export NAME=cubswifit JB_OK=1 WAIT=${WAIT:-230} LOOP_START=${LOOP_START:-110} OUT=${OUT:-/tmp/g-wifi}
export ARM='touch /data/local/ios/wifi'
export DISARM='rm -f /data/local/ios/wifi'
export LAUNCHER_PATCH="$HOME/wifi_launcher_patch.py"
export EVIDENCE='adb shell "tail -5 /data/local/ios/wifisrv.log /data/local/ios/wifiscansrv.log /data/local/ios/wifiapp.log" > $OUT/wifi-daemons.txt 2>&1'
exec bash "$HOME/run_guarded.sh"
