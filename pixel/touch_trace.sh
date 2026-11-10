T=/sys/kernel/tracing
old=$(cat /proc/sys/kernel/kptr_restrict); echo 0 > /proc/sys/kernel/kptr_restrict
va_spi=$(grep "phys=0x000000000da2c000" /proc/vmallocinfo | head -1 | sed 's/-.*//')
va_pin=$(grep "phys=0x000000000e500000" /proc/vmallocinfo | head -1 | sed 's/-.*//')
echo "spi VA $va_spi pinctrl VA $va_pin"
echo "$va_spi $va_pin" > /data/local/tmp/touch_va.txt
echo 0 > /proc/sys/kernel/kptr_restrict; echo $old > /proc/sys/kernel/kptr_restrict
echo 0 > $T/tracing_on; echo > $T/trace; echo 0 > $T/events/enable
for e in rwmmio_write rwmmio_read; do
  echo "(addr >= $va_spi && addr < $va_spi + 0x100) || (addr >= $va_pin && addr < $va_pin + 0x7c000)" > $T/events/rwmmio/$e/filter
  echo 1 > $T/events/rwmmio/$e/enable
done
cmd notification post -S bigtext -t "TOUCH TRACE" tt "Swipe and tap the screen NOW, for 45 seconds" >/dev/null 2>&1
cmd vibrator_manager vibrate -f 500 >/dev/null 2>&1
sleep 5
echo 1 > $T/tracing_on
sleep 45
echo 0 > $T/tracing_on
cp $T/trace /data/local/tmp/touch_trace.txt
for e in rwmmio_write rwmmio_read; do echo 0 > $T/events/rwmmio/$e/enable; echo 0 > $T/events/rwmmio/$e/filter; done
wc -l /data/local/tmp/touch_trace.txt
