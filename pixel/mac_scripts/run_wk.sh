#!/bin/bash
# One supervised boot of the WKWebView probe (payload cubswk, system image with WKProbe.app pushed as system-jbtest.img): screenshot burst from
# 110 s on (cv*.bin), kernel log with the "wkprobe:" lines. Evidence in /tmp/g-wk.
set -u
export PATH="$PATH:/opt/homebrew/bin"
export NAME=cubswk JB_OK=1 WAIT=${WAIT:-270} LOOP=1 LOOP_START=${LOOP_START:-120} OUT=${OUT:-/tmp/g-wk}
export PUSH="$HOME/hopay/system-jb.apfs:/data/local/ios/system-jbtest.img"
export LAUNCHER_SED='s#system-jb.img#system-jbtest.img#g'
exec bash "$HOME/run_guarded.sh"
