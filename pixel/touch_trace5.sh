T=/sys/kernel/tracing
echo mono > $T/trace_clock
echo 0 > $T/tracing_on; echo > $T/trace; echo 0 > $T/events/enable
echo 1 > $T/events/spi/spi_transfer_stop/enable
cmd vibrator_manager vibrate -f 800 >/dev/null 2>&1
cmd notification post -S bigtext -t TOUCH_TEST tt "Touch: HOLD top-left 3s, top-right 3s, bottom-left 3s, bottom-right 3s, centre 3s, then swipe" >/dev/null 2>&1
getevent -lt /dev/input/event2 > /data/local/tmp/ge5.txt &
GP=$!
sleep 2
echo 1 > $T/tracing_on
sleep 65
echo 0 > $T/tracing_on
kill $GP
cp $T/trace /data/local/tmp/touch_trace5.txt
echo 0 > $T/events/spi/spi_transfer_stop/enable
echo local > $T/trace_clock
echo done5 > /data/local/tmp/done5.txt
