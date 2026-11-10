S=/sys/devices/platform/da2c000.spi
echo "before: $(cat $S/power/runtime_status) control=$(cat $S/power/control)"
echo on > $S/power/control; sleep 1
echo "after: $(cat $S/power/runtime_status) control=$(cat $S/power/control)"
P=$(readlink -f $S/spi_master/spi8/spi8.0 | sed 's#/spi_master.*##'); echo $P
echo "spi8.0 power: $(cat $S/spi_master/spi8/spi8.0/power/control 2>&1) $(cat $S/spi_master/spi8/spi8.0/power/runtime_status 2>&1)"
echo "== gpio debugfs"; grep -i -E "tcm|touch|syna|spi8|cs" /sys/kernel/debug/gpio 2>/dev/null | head -10
sed -n 1,12p /sys/kernel/debug/gpio 2>/dev/null
echo "== pinctrl debug"; ls /sys/kernel/debug/pinctrl/ 2>/dev/null | head; 
rmmod cubs_stage 2>/dev/null; rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram; insmod /data/local/tmp/cubs_stage.ko; sleep 2
for o in 0 4 8 16 20 24 28 32 36 40 44 48 52 56 60 64 68 72 76 80 84 88 92 96; do printf "M%x" $((0xda2c000 + o)) > /dev/cubs_go; done
dmesg | grep -a "cubs_stage: M" | tail -24 | cut -c1-120
