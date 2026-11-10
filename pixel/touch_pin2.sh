for d in e500000.pinctrl da2c000.spi; do echo on > /sys/devices/platform/$d/power/control; done
sleep 1
for d in e500000.pinctrl da2c000.spi; do echo "$d $(cat /sys/devices/platform/$d/power/runtime_status)"; done
rmmod cubs_stage 2>/dev/null; rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram; insmod /data/local/tmp/cubs_stage.ko; sleep 2
for p in 23 54; do for o in 0 32 64; do printf "M%x" $((0xe500000 + p*4096 + o)) > /dev/cubs_go; done; done
dmesg | grep -a "cubs_stage: M e5" | tail -6 | cut -c12-120
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
grep -E "gpio-(537|568)" /sys/kernel/debug/gpio
