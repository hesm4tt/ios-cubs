T=/sys/kernel/tracing
G=/sys/devices/virtual/goog_touch_interface/gti.0
ls $T/events/spi 2>&1 | head
cat $T/events/spi/spi_transfer_stop/format 2>&1 | tail -8
echo 0 > $T/tracing_on; echo > $T/trace; echo 0 > $T/events/enable
echo 1 > $T/events/spi/enable
echo 1 > $T/tracing_on
cat $G/ping >/dev/null; echo 1 > $G/reset
sleep 8
echo 0 > $T/tracing_on
cp $T/trace /data/local/tmp/touch_trace3.txt
echo 0 > $T/events/spi/enable
wc -l /data/local/tmp/touch_trace3.txt
