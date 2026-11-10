#!/bin/bash
# End-to-end sideload test (payload cubslsp built by lsprobe_test.sh): the inbox package is installed by cubs-persist.sh, registered from a bundle
# container, SpringBoard restarted once, then lsprobe polls SBSLaunchApplicationWithIdentifier for the app (success = rc 0) and a screenshot burst
# shows the app. Long run: phone-side watchdog 640 s. Evidence in /tmp/g-sl2.
set -u
export PATH="$PATH:/opt/homebrew/bin"
export NAME=cubslsp JB_OK=1 WDOG=${WDOG:-1500} WAIT=${WAIT:-1100} LOOP=1 LOOP_START=${LOOP_START:-700} LOOP_N=${LOOP_N:-100} OUT=${OUT:-/tmp/g-sl2}
export PUSH="$HOME/hopay/system-jb.apfs:/data/local/ios/system-jbtest.img"
export LAUNCHER_SED='s#system-jb.img#system-jbtest.img#g'
exec bash "$HOME/run_guarded.sh"
