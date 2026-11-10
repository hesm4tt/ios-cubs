#!/bin/bash
# One supervised boot of the PRODUCTION payload (cubswifi) and production system image, to see that the brightness bridge raises the panel from
# Android's dim level: the backlight value is sampled every 3 s on the phone (bl.log). Needs /tmp/cubswifi-offsets ("28c8000 17fe00000").
# Evidence in /tmp/g-prodbr.
set -u
export PATH="$PATH:/opt/homebrew/bin"
export NAME=cubswifi JB_OK=1 WAIT=${WAIT:-200} LOOP=0 OUT=${OUT:-/tmp/g-prodbr}
export LAUNCHER_EXTRA='( for i in $(seq 1 90); do echo "$(date +%T) $(cat /sys/class/backlight/panel0-backlight/brightness)" >> $D/bl.log; sleep 3; done ) &'
export ARM='rm -f /data/local/ios/bl.log'
export DISARM='rm -f /data/local/ios/bl.log'
export EVIDENCE='adb pull /data/local/ios/bl.log $OUT/bl.log >/dev/null 2>&1'
exec bash "$HOME/run_guarded.sh"
