d=$(ls -d /sys/firmware/devicetree/base/*/spi@da2c000 /sys/firmware/devicetree/base/*/*/spi@da2c000 2>/dev/null | head -1)
[ -z "$d" ] && d=$(find /sys/firmware/devicetree/base -maxdepth 4 -name "spi@da2c000" | head -1)
echo SPI NODE $d
for f in $d/*; do n=$(basename $f); [ -f $f ] && echo "$n: $(od -An -tx1 -v $f | head -3 | tr -d '\n' | cut -c1-200)"; done
t=$d/touchscreen@0
echo TOUCH NODE
for f in $t/*; do n=$(basename $f); [ -f $f ] && echo "$n: $(od -An -tx1 -v $f | head -4 | tr -d '\n' | cut -c1-240)"; done
cat $t/compatible; echo
cat $t/synaptics,irq-gpio 2>/dev/null | od -An -tx1
p=$(find /sys/firmware/devicetree/base -maxdepth 4 -name "pinctrl@e500000" | head -1)
echo PINCTRL $p
for f in $p/*; do n=$(basename $f); [ -f $f ] && echo "$n: $(od -An -tx1 -v $f | head -3 | tr -d '\n' | cut -c1-200)"; done
ls $p | head -40
