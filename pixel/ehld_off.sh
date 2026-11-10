P=/sys/module/google_ehld_coreinstr/parameters/noehld
ls -l $P
echo 1 > $P; echo "noehld now: $(cat $P)"
ls /sys/module/hardlockup_watchdog/parameters 2>/dev/null
cat /sys/module/hardlockup_watchdog/parameters/* 2>/dev/null | head -3
