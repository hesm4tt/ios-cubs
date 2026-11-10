rmmod google_ehld_coreinstr; echo "ehld rmmod rc=$?"
rmmod cubs_stage 2>/dev/null; rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram
insmod /data/local/tmp/cubs_stage.ko; sleep 2
printf "E922000000:17ff00000" > /dev/cubs_go
echo 0 > /sys/devices/system/cpu/cpu6/online; sleep 1
printf "N600:2" > /dev/cubs_go
sleep 3
printf "A600" > /dev/cubs_go
echo V > /dev/cubs_go
dmesg | grep -a -E "cubs_stage: (CPU_ON|amp|affinity)" | tail -6 | cut -c1-200
echo 1 > /sys/devices/system/cpu/cpu6/online; echo "online: $(cat /sys/devices/system/cpu/online)"
