#!/bin/bash
# One supervised boot of the system image with brightbridge in the prefix (built by bright_prod_test.sh): the image is pushed as system-jbtest.img
# for this run only; the panel's backlight value is sampled every 3 s on the phone (bl.log). Evidence in /tmp/g-bp.
set -u
export PATH="$PATH:/opt/homebrew/bin"
export NAME=cubsbp JB_OK=1 WAIT=${WAIT:-200} LOOP=0 OUT=${OUT:-/tmp/g-bp}
export PUSH="$HOME/hopay/system-jb.apfs:/data/local/ios/system-jbtest.img"
export LAUNCHER_SED='s#system-jb.img#system-jbtest.img#g'
export LAUNCHER_EXTRA='( for i in $(seq 1 90); do echo "$(date +%T) $(cat /sys/class/backlight/panel0-backlight/brightness)" >> $D/bl.log; sleep 3; done ) &'
export ARM='rm -f /data/local/ios/bl.log'
export DISARM='rm -f /data/local/ios/bl.log'
export EVIDENCE='adb pull /data/local/ios/bl.log $OUT/bl.log >/dev/null 2>&1; adb pull /data/local/ios/persistsrv.log $OUT/persistsrv.log >/dev/null 2>&1'
exec bash "$HOME/run_guarded.sh"
