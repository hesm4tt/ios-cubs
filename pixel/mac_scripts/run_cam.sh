#!/bin/bash
# One supervised boot of the camera viewfinder probe (payload cubscp, system image with CamProbe.app pushed as system-jbtest.img): screenshot burst
# from 120 s on (cv*.bin), kernel log with the job output. The Android camera is NOT started (the chart frames come from the kernel's fake sensor).
# Evidence in /tmp/g-cam.
set -u
export PATH="$PATH:/opt/homebrew/bin"
export NAME=cubscp JB_OK=1 WAIT=${WAIT:-270} LOOP=1 LOOP_START=${LOOP_START:-120} OUT=${OUT:-/tmp/g-cam}
export PUSH="$HOME/hopay/system-jb.apfs:/data/local/ios/system-jbtest.img"
export LAUNCHER_SED='s#system-jb.img#system-jbtest.img#g'
exec bash "$HOME/run_guarded.sh"
