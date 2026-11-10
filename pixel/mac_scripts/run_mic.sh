#!/bin/bash
# run_mic.sh (Mac): supervised test of the microphone for iOS: payload cubsmic (production + boot arg cubs_mic=1, built by build_big_payload.sh from
# xnu bsd/dev/redwood_cubs_mic.c), micsrv (pcwork/mic/micsrv.c) started by the launcher next to glsrv. Nothing persistent is changed.
# A person opens Voice Memos in iOS, taps record, talks, and stops; evidence: kernel log "mic:" lines, micsrv.log.
set -eu
export PATH="$PATH:/opt/homebrew/bin"
export NAME=cubsmic JB_OK=1 WDOG=${WDOG:-800} WAIT=${WAIT:-420} OUT=/tmp/guarded-cubsmic
export PUSH="$HOME/micsrv:/data/local/ios/micsrv"
export LAUNCHER_SED='/^RING_DEV=\/dev\/cubs_ram RING_BASE=0 .\/glsrv /a\
( chmod 755 $D/micsrv; $D/micsrv > $D/micsrv.log 2>\&1 \& )'
export EVIDENCE='adb pull /data/local/ios/micsrv.log "$OUT/micsrv.log" >/dev/null || true'
exec bash $HOME/run_guarded.sh
