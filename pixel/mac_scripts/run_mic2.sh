#!/bin/bash
# run_mic2.sh (Mac): one supervised boot of the microphone test (image from mic_test.sh pushed as system-jbtest.img; payload cubsmict = that root + cubs_mic=1;
# micsrv started next to glsrv). MicTest.app is launched by a boot job after the unlock swipe; it shows the live microphone level on the screen and its log
# (/tmp/mictest.log, /tmp/tccfake.log) is cat'ed into the kernel log three times. A person makes noise near the bottom microphone from ~60 s after the start.
set -u
export PATH="$PATH:/opt/homebrew/bin"
export NAME=cubsmict JB_OK=1 WDOG=${WDOG:-800} WAIT=${WAIT:-400} LOOP=1 LOOP_START=${LOOP_START:-100} OUT=/tmp/guarded-cubsmict
export PUSH="$HOME/hopay/system-jb.apfs:/data/local/ios/system-jbtest.img"
export LAUNCHER_SED='s#system-jb.img#system-jbtest.img#g
/^RING_DEV=\/dev\/cubs_ram RING_BASE=0 .\/glsrv /a\
( chmod 755 $D/micsrv; $D/micsrv > $D/micsrv.log 2>\&1 \& )'
adb push $HOME/micsrv /data/local/ios/micsrv >/dev/null; adb shell chmod 755 /data/local/ios/micsrv
export EVIDENCE='adb pull /data/local/ios/micsrv.log "$OUT/micsrv.log" >/dev/null || true'
exec bash $HOME/run_guarded.sh
