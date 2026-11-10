T=/sys/kernel/tracing
G=/sys/devices/virtual/goog_touch_interface/gti.0
echo 0 > $T/tracing_on; echo > $T/trace; echo 0 > $T/events/enable
cat $T/available_tracers
echo function > $T/current_tracer 2>&1
echo > $T/set_ftrace_filter 2>&1
sh -c 'echo $$ > '$T'/set_ftrace_pid; echo 1 > '$T'/tracing_on; cat '$G'/ping > /dev/null; echo 0 > '$T'/tracing_on' 
echo nop > $T/current_tracer
cp $T/trace /data/local/tmp/fg.txt
wc -l /data/local/tmp/fg.txt
grep -E "gpio|pinctrl|spi_set_cs|goog|mbu" /data/local/tmp/fg.txt | awk '{print $NF" <- "$(NF-2)}' | sort | uniq -c | sort -rn | head -40
