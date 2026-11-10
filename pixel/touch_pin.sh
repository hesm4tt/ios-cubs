rmmod cubs_stage 2>/dev/null; rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram; insmod /data/local/tmp/cubs_stage.ko; sleep 2
for o in 0 32 64 96 128 160 192 224 256 288 320 352 384 416 448 480; do printf "M%x" $((0xe500000 + o)) > /dev/cubs_go; done
dmesg | grep -a "cubs_stage: M e5" | tail -16 | cut -c12-120
D=/sys/kernel/debug/pinctrl/e500000.pinctrl
grep -E "gpio-(537|568)" /sys/kernel/debug/gpio
