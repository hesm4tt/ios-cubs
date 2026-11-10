rmmod cubs_stage 2>/dev/null; rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram
insmod /data/local/tmp/cubs_stage.ko; sleep 2
for f in 0 1 2 3 4 5 6 7; do a=$((0x92a8000 + f*0x20000)); printf "X%x" $((a+8)) > /dev/cubs_go; printf "X%x" $((a+12)) > /dev/cubs_go; done
dmesg | grep -a "cubs_stage: X 92" | tail -16 | cut -c12-100
