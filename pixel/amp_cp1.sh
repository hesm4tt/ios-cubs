rmmod google_ehld_coreinstr 2>/dev/null
rmmod cubs_stage 2>/dev/null; rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram
insmod /data/local/tmp/cubs_stage.ko; sleep 1
cat /data/local/tmp/ho.payload > /dev/cubs_stage
printf "P1" > /dev/cubs_go
taskset 1 sh -c "echo S > /dev/cubs_go"
printf "L0:2000000" > /dev/cubs_go
echo C > /dev/cubs_go
echo 0 > /sys/devices/system/cpu/cpu6/online; sleep 1
printf "N600:1" > /dev/cubs_go
printf "H2900:8" > /dev/cubs_go
printf "H1000:12" > /dev/cubs_go
dmesg | grep -a -E "H[|]" | tail -6 | cut -c1-170
sleep 2
echo V > /dev/cubs_go
dmesg | grep -a -E "cubs_stage: amp" | tail -1 | cut -c1-190
