T=/sys/kernel/tracing
G=/sys/devices/virtual/goog_touch_interface/gti.0
cat $G/fw_ver $G/panel_id $G/vendor 2>&1 | head -5
echo 0 > $T/tracing_on; echo > $T/trace; echo 0 > $T/events/enable
echo 65536 > $T/buffer_size_kb 2>/dev/null
echo 1 > $T/events/rwmmio/rwmmio_write/enable; echo 1 > $T/events/rwmmio/rwmmio_read/enable
echo 1 > $T/tracing_on
cat $G/ping; cat $G/fw_ver
echo 1 > $G/reset
sleep 8
cat $G/fw_ver
echo 0 > $T/tracing_on
cp $T/trace /data/local/tmp/touch_trace2.txt
echo 0 > $T/events/rwmmio/rwmmio_write/enable; echo 0 > $T/events/rwmmio/rwmmio_read/enable
wc -l /data/local/tmp/touch_trace2.txt
grep -c "dw_spi\|spi_" /data/local/tmp/touch_trace2.txt
