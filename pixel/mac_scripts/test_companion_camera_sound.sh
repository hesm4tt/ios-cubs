#!/bin/bash
set -u
export PATH="$PATH:/opt/homebrew/bin"
candidate=/tmp/cubs-wifi-companion-candidate.apk
backup=/tmp/cubs-companion-installed.apk
test -s "$candidate" && test -s "$backup" || { echo candidate-or-backup-missing; exit 1; }
updated=0
cleanup() {
  if [ "$updated" = 1 ]; then adb install -r "$backup" >/dev/null 2>&1 && echo companion-restored || echo companion-restore-failed; fi
  adb shell rm -f /data/local/tmp/cubs-bridge-smoke /data/local/tmp/test_bridge_candidate_android.sh >/dev/null 2>&1 || :
}
trap cleanup EXIT
if adb shell 'pidof com.cubs.cam >/dev/null' 2>/dev/null; then echo companion-busy; exit 1; fi
adb install -r "$candidate" >/dev/null || exit 1
updated=1
adb push /tmp/cubs-bridge-smoke /tmp/test_bridge_candidate_android.sh /data/local/tmp/ >/dev/null || exit 1
printf '%s\n' 'chmod 755 /data/local/tmp/cubs-bridge-smoke; sh /data/local/tmp/test_bridge_candidate_android.sh' | adb shell /data/adb/ksu/bin/ksud debug su
