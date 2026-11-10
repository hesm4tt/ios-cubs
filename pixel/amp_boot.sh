rmmod google_ehld_coreinstr; echo "ehld rmmod rc=$?"
echo 0 > /sys/module/hardlockup_watchdog/parameters/hardlockup_panic
echo 0 > /proc/sys/kernel/watchdog
fq=/sys/devices/system/cpu/cpufreq/policy6
echo $(cat $fq/cpuinfo_max_freq) > $fq/scaling_max_freq; echo $(cat $fq/cpuinfo_max_freq) > $fq/scaling_min_freq
rmmod cubs_stage 2>/dev/null; rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram
insmod /data/local/tmp/cubs_stage.ko; sleep 2
cat /data/local/tmp/ho.payload > /dev/cubs_stage
taskset 1 sh -c "echo S > /dev/cubs_go"
printf O28a8000 > /dev/cubs_go
(cat /dev/block/by-name/modem_a /dev/block/by-name/modem_b | head -c 2492203008) > /dev/cubs_ram
printf "L0:97168000" > /dev/cubs_go
echo C > /dev/cubs_go
echo 0 > /sys/devices/system/cpu/cpu6/online; sleep 1
echo "online: $(cat /sys/devices/system/cpu/online)"
printf "N600:1" > /dev/cubs_go
sleep 12
echo V > /dev/cubs_go
printf "D1d189f8:6000" > /dev/cubs_go
printf "H1bf9208:8" > /dev/cubs_go
printf "A600" > /dev/cubs_go
dmesg | grep -a -E "cubs_stage: (CPU_ON|amp|affinity)|X[|]|H[|]" | tail -70 | cut -c1-170
