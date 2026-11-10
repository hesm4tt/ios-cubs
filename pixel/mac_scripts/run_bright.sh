#!/bin/bash
# One supervised boot of the brightness bridge test (payload cubsbr from bright_test.sh): the new persistsrv is pushed as persistsrv.test and used
# for this run only; the panel's backlight value is sampled every 3 s on the phone (bl.log); evidence in /tmp/g-bright.
set -u
export PATH="$PATH:/opt/homebrew/bin"
export NAME=cubsbr JB_OK=1 WAIT=${WAIT:-260} LOOP=0 OUT=${OUT:-/tmp/g-bright}
export PUSH="$HOME/persistsrv.new:/data/local/ios/persistsrv.test"
export LAUNCHER_SED='s#\$D/persistsrv#$D/persistsrv.test#g'
export LAUNCHER_EXTRA='( for i in $(seq 1 90); do echo "$(date +%T) $(cat /sys/class/backlight/panel0-backlight/brightness)" >> $D/bl.log; sleep 3; done ) &'
export ARM='rm -f /data/local/ios/bl.log'
export DISARM='rm -f /data/local/ios/bl.log'
export EVIDENCE='adb pull /data/local/ios/bl.log $OUT/bl.log >/dev/null 2>&1; adb pull /data/local/ios/persistsrv.test.log $OUT/persistsrv.log >/dev/null 2>&1'
exec bash "$HOME/run_guarded.sh"
