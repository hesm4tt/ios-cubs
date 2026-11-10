#!/bin/bash
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
p=$(adb shell pm path com.cubs.cam | tr -d '\r' | sed -n 's/^package://p' | head -1)
[ -n "$p" ] || exit 1
adb pull "$p" /tmp/cubs-companion-after-test.apk >/dev/null 2>&1
cmp -s /tmp/cubs-companion-after-test.apk /tmp/cubs-companion-installed.apk || { echo rollback-mismatch; exit 1; }
echo rollback-byte-match
adb shell 'getprop sys.boot_completed'
