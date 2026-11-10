rmmod cubs_stage 2>/dev/null
insmod /data/local/tmp/cubs_stage.ko; sleep 1
for n in 0 1 2 3 4 5; do
 b=$((0xf618000 + 0x4000*n))
 for o in 0 32 40 64 88 128; do printf "M%x" $((b+o)) > /dev/cubs_go; done
done
dmesg | grep "cubs_stage: M" | tail -40 | cut -c1-150
