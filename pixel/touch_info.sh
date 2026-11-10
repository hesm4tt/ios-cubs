ls -l /sys/bus/spi/devices/ 2>&1 | head
for d in /sys/bus/spi/devices/*; do echo "== $d"; ls $d | head -20; cat $d/modalias 2>/dev/null; readlink $d/driver 2>/dev/null; done
echo "== interrupts"; grep -i -E "touch|syna|tcm|spi" /proc/interrupts | head
echo "== gpio"; grep -i -E "touch|tp_|ts_" /sys/kernel/debug/gpio 2>/dev/null | head
echo "== touch module params"; ls /sys/module/syna_touch/parameters 2>/dev/null | head; lsmod | grep -i -E "syna|touch" | head
echo "== input"; for i in /sys/class/input/input*; do echo $i $(cat $i/name 2>/dev/null); done 2>/dev/null | head -20
