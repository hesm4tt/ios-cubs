#!/bin/bash
set -u
export PATH=$PATH:/opt/homebrew/bin
pkg=com.cubs.scantest
if adb shell pm path "$pkg" 2>/dev/null | grep -q '^package:'; then echo test-package-already-exists; exit 1; fi
installed=0
cleanup() { if [ "$installed" = 1 ]; then adb uninstall "$pkg" >/dev/null 2>&1 || echo test-uninstall-failed; fi; }
trap cleanup EXIT
apk=$(cat /tmp/cubs-scan-test-apk-path) || exit 1
adb install "$apk" >/dev/null || exit 1
installed=1
adb shell pm grant "$pkg" android.permission.ACCESS_FINE_LOCATION || exit 1
adb push /tmp/wifisrv /tmp/wifiscansrv /tmp/test_real_scan_android.sh /data/local/tmp/ >/dev/null || exit 1
adb shell "echo sh /data/local/tmp/test_real_scan_android.sh | /data/adb/ksu/bin/ksud debug su"
