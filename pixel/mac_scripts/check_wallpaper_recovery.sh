#!/bin/bash
set -u
export PATH="$PATH:/opt/homebrew/bin"
printf '%s\n' 'D=/data/local/ios
cmp -s "$D/ho.payload" "$D/ho.payload.prod" && echo payload-ok || echo payload-mismatch
if [ -f "$D/ios_start.pre-cubswall" ]; then
  cmp -s "$D/ios_start.sh" "$D/ios_start.pre-cubswall" && echo launcher-ok || echo launcher-mismatch
else echo launcher-backup-missing; fi
for f in boot_ios smp cam snd camid camdelay noring cpu6_khz; do [ ! -e "$D/$f" ] || echo "flag-present:$f"; done
if pidof drmfb2 >/dev/null; then echo ios-active; else echo no-ios-display; fi
if [ -f "$D/cubswall-watchdog.log" ]; then tail -4 "$D/cubswall-watchdog.log"; fi' | adb shell /data/adb/ksu/bin/ksud debug su
