#!/bin/bash
# One supervised boot of the LaunchServices probe payload (cubslsp, built by lsprobe_test.sh); evidence in /tmp/g-lsp (kernel-log.bin has the lsprobe lines).
set -u
export PATH="$PATH:/opt/homebrew/bin"
export NAME=cubslsp JB_OK=1 WAIT=${WAIT:-230} LOOP=0 OUT=${OUT:-/tmp/g-lsp}
exec bash "$HOME/run_guarded.sh"
