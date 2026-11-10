#!/bin/bash
set -eu
export PATH="$PATH:/opt/homebrew/bin"
printf '%s\n' 'D=/data/local/ios
cmp -s "$D/ho.payload" "$D/ho.payload.prod" || exit 1
cmp -s "$D/ios_start.sh" "$D/ios_start.pre-cubswall" || exit 1
rm -f "$D/ios_start.pre-cubswall" /data/local/tmp/cubswall-log.bin /data/local/tmp/cubswall-shot.bin /data/local/tmp/cubswall-launcher.sh /data/local/tmp/cubswall.payload
sync
echo temporary-test-files-removed' | adb shell /data/adb/ksu/bin/ksud debug su
