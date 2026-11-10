find /sys -iname "*ehld*" 2>/dev/null | head -12
for d in $(find /sys/devices -maxdepth 3 -iname "*ehld*" 2>/dev/null | head -3); do echo "== $d"; ls $d | head -30; done
ls /sys/module | grep -i -E "ehld|hardlockup|watchdog|lockup" | head
for m in $(ls /sys/module | grep -i -E "ehld"); do echo "== module $m"; ls /sys/module/$m/parameters 2>/dev/null; for p in /sys/module/$m/parameters/*; do echo "$p = $(cat $p 2>/dev/null)"; done; done
cat /proc/sys/kernel/hardlockup_panic /proc/sys/kernel/nmi_watchdog /proc/sys/kernel/watchdog 2>/dev/null
