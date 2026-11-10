#!/bin/bash
set -u
export PATH="$PATH:/opt/homebrew/bin"
candidate=/tmp/cubs-wifi-companion-candidate.apk
backup=/tmp/cubs-companion-installed.apk
test -s "$candidate" && test -s "$backup" || { echo candidate-or-backup-missing; exit 1; }
updated=0
cleanup() {
  if [ "$updated" = 1 ]; then
    if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && adb shell '! pidof drmfb2 >/dev/null' 2>/dev/null; then
      adb install -r "$backup" >/dev/null 2>&1 && echo companion-restored || echo companion-restore-failed
    else echo companion-restore-unverified; fi
  fi
}
trap cleanup EXIT
if adb shell 'pidof com.cubs.cam >/dev/null' 2>/dev/null; then echo companion-busy; exit 1; fi
adb install -r "$candidate" >/dev/null || exit 1
updated=1
bash /tmp/run_wifi_onecore.sh
