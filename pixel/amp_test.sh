rmmod cubs_stage 2>/dev/null; rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram
insmod /data/local/tmp/cubs_stage.ko; sleep 2
cat /data/local/tmp/ho.payload > /dev/cubs_stage
taskset 1 sh -c "echo S > /dev/cubs_go"
echo 0 > /sys/devices/system/cpu/cpu6/online; sleep 1
echo "online: $(cat /sys/devices/system/cpu/online)"
printf "N600:0" > /dev/cubs_go
sleep 2
echo V > /dev/cubs_go
dmesg | grep -a -E "cubs_stage: (CPU_ON|amp|loader-return)" | tail -4 | cut -c1-140
echo 1 > /sys/devices/system/cpu/cpu6/online; sleep 1
echo "online after: $(cat /sys/devices/system/cpu/online)"
