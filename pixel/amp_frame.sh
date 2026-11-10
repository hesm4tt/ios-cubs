rmmod google_ehld_coreinstr 2>/dev/null
rmmod cubs_stage 2>/dev/null; rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram
insmod /data/local/tmp/cubs_stage.ko; sleep 1
cat /data/local/tmp/ho.payload > /dev/cubs_stage
taskset 1 sh -c "echo S > /dev/cubs_go"
printf "F922002900:0:100" > /dev/cubs_go
printf "L0:2000000" > /dev/cubs_go
echo C > /dev/cubs_go
echo 0 > /sys/devices/system/cpu/cpu6/online; sleep 1
printf "N600:1" > /dev/cubs_go
sleep 4
printf "H207be00:64" > /dev/cubs_go
printf "H2078000:16" > /dev/cubs_go
dmesg | grep -a "H[|] 207" | tail -22 | cut -c1-150
