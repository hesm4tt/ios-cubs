#!/bin/bash
set -u
export PATH="$PATH:/opt/homebrew/bin"
candidate=/tmp/cubs-wifi-companion-candidate.apk
backup=/tmp/cubs-companion-installed.apk
test -s "$candidate" && test -s "$backup" || { echo candidate-or-backup-missing; exit 1; }
updated=0
cleanup() {
  if [ "$updated" = 1 ]; then
    adb install -r "$backup" >/dev/null 2>&1 && echo companion-restored || echo companion-restore-failed
  fi
  adb shell rm -f /data/local/tmp/cubs-wifi-candidate-test.sh /data/local/tmp/cubs-wifi-status-candidate /data/local/tmp/cubs-wifi-scan-candidate >/dev/null 2>&1 || :
}
trap cleanup EXIT
if adb shell 'pidof com.cubs.cam >/dev/null' 2>/dev/null; then echo companion-busy; exit 1; fi
python3 - <<'PY' || exit 1
s=open('/tmp/test_real_scan_android.sh').read()
assert s.count('pkg=com.cubs.scantest')==1
s=s.replace('pkg=com.cubs.scantest','pkg=com.cubs.cam')
s=s.replace('/data/local/tmp/wifiscansrv','/data/local/tmp/cubs-wifi-scan-candidate')
s=s.replace('/data/local/tmp/wifisrv','/data/local/tmp/cubs-wifi-status-candidate')
open('/tmp/cubs-wifi-candidate-test.sh','w').write(s)
PY
adb install -r "$candidate" >/dev/null || exit 1
updated=1
adb push /tmp/cubs-wifi-candidate-test.sh /tmp/wifisrv /tmp/wifiscansrv /data/local/tmp/ >/dev/null || exit 1
printf '%s\n' 'mv /data/local/tmp/wifisrv /data/local/tmp/cubs-wifi-status-candidate && mv /data/local/tmp/wifiscansrv /data/local/tmp/cubs-wifi-scan-candidate && chmod 755 /data/local/tmp/cubs-wifi-status-candidate /data/local/tmp/cubs-wifi-scan-candidate && sh /data/local/tmp/cubs-wifi-candidate-test.sh' | adb shell /data/adb/ksu/bin/ksud debug su
