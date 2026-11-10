T=/sys/kernel/tracing
echo 0 > $T/tracing_on; echo > $T/trace; echo 0 > $T/events/enable
echo 1 > $T/events/spi/spi_transfer_stop/enable
echo 1 > $T/tracing_on
sleep 190
echo 0 > $T/tracing_on
cp $T/trace /data/local/tmp/touch_trace4.txt
echo 0 > $T/events/spi/spi_transfer_stop/enable
