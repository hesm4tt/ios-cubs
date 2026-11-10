rmmod cubs_stage 2>/dev/null; rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram
insmod /data/local/tmp/cubs_stage.ko; sleep 2
( for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do input swipe 540 1800 540 600 120; input swipe 540 600 540 1800 120; done ) &
sleep 2
M() { printf "M%x" $1 > /dev/cubs_go; }
for n in 2 0 3; do b=$((0xf618000 + 0x4000*n)); for o in 0 32 40 64 88 128; do M $((b+o)); done; done
dmesg | grep "cubs_stage: M" | tail -20 | cut -c1-150
