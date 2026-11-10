#!/system/bin/sh
D=/data/local/tmp/cubs_watchdog_reboot_test
rm -f "$D/ho.payload" "$D/ho.payload.prod" "$D/ios_start.sh" "$D/ios_start.pre-wifistatus" "$D/ios_start.log" "$D/reboot-requested"
rmdir "$D" && echo test-files-removed
