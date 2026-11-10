for m in hardlockup_debug hardlockup_watchdog google_ehld_coreinstr; do echo "== $m"; for p in /sys/module/$m/parameters/*; do echo "$p = $(cat $p 2>/dev/null)"; done; ls /sys/module/$m/holders 2>/dev/null; done
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
ls /sys/kernel/debug | grep -i -E "ehld|lockup|hardlock" | head
ls /sys/kernel/debug/ehld* 2>/dev/null | head -20
lsmod | grep -i -E "ehld|hardlock"
ls /vendor_dlkm/lib/modules /vendor/lib/modules 2>/dev/null | grep -i -E "ehld|hardlock"
