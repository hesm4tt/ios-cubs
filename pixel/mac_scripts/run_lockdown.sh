#!/bin/bash
# Supervised iOS boot with lockdownd (production payload cubswifi + the rebuilt system image pushed as system-jbtest.img): long enough (WAIT 700 s,
# watchdog 900 s) to press Trust in the Mac's Finder while iOS runs. The USB gadget (usbmux_gadget.sh apply, keep flag) is expected to be applied.
# Evidence in /tmp/g-lockdown (kernel log with the "cubs-persist: lockdown:" lines).
set -u
export PATH="$PATH:/opt/homebrew/bin"
export NAME=cubswifi JB_OK=1 WDOG=900 WAIT=${WAIT:-700} LOOP=0 OUT=${OUT:-/tmp/g-lockdown}
export PUSH="$HOME/hopay/system-jb.apfs:/data/local/ios/system-jbtest.img"
export LAUNCHER_SED='s#system-jb.img#system-jbtest.img#g'
exec bash "$HOME/run_guarded.sh"
