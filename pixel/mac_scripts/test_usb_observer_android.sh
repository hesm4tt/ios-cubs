#!/bin/bash
set -eu
export PATH="$PATH:/opt/homebrew/bin"
dir=$(adb shell 'mktemp -d /data/local/tmp/cubs-usb-observe.XXXXXX' | tr -d '\r')
case "$dir" in /data/local/tmp/cubs-usb-observe.*) ;; *) echo invalid-test-dir; exit 1;; esac
cleanup() { adb shell rm -rf "$dir" >/dev/null 2>&1 || echo cleanup-failed; }
trap cleanup EXIT
adb push /tmp/cubs-usb-observe.sh "$dir/observe.sh" >/dev/null
adb shell "sh '$dir/observe.sh' '$dir/logs' 2 1"
adb shell "cat '$dir/logs/current.log'"
