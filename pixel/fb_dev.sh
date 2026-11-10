rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram; rmmod cubs_stage 2>/dev/null
insmod /data/local/tmp/cubs_stage.ko; sleep 2
cat /data/local/tmp/ho.payload > /dev/cubs_stage
taskset 1 sh -c "echo S > /dev/cubs_go"
printf O249c000 > /dev/cubs_go
(cat /dev/block/by-name/modem_a /dev/block/by-name/modem_b | head -c 2492203008) > /dev/cubs_ram
echo C > /dev/cubs_go
dmesg | grep cubs_stage | tail -4
for c in 1 2 3 4 5 6; do echo 0 > /sys/devices/system/cpu/cpu$c/online; done
sync; echo JUMPING
taskset 1 sh -c "echo K > /dev/cubs_go"
