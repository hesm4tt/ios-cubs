#!/system/bin/sh
# iOS (XNU on CPU6) beside live Android + GPU server: the whole Metal-route proof of concept.
# needs on the phone: ho.payload (bootreg'd, cpu0 reg 0x600), cubs_stage.ko, drmfb2, gserver, fixture.bc, root.apfs partitions as md0 source
# env: RAMOFF (hex), LISTOFF (hex), WAIT (seconds)
L=/data/local/tmp/amp_gpu.log
exec > $L 2>&1
cd /data/local/tmp
rm -f tri.ppm
rmmod google_ehld_coreinstr 2>/dev/null
for d in e500000.pinctrl da2c000.spi; do echo on > /sys/devices/platform/$d/power/control; done
# heat: CPU0 stays on its governor; the XNU core (CPU6) runs at a moderate clock, not flat out at 4.1 GHz
fq=/sys/devices/system/cpu/cpufreq/policy6
echo 3033000 > $fq/scaling_max_freq; echo 3033000 > $fq/scaling_min_freq
# thermal guard: log temperatures every 30 s and drop back to Android (kernel panic reboot) if the battery passes 43 C or BIG 80 C
( while true; do b=$(cat /sys/class/power_supply/battery/temp); big=$(for z in /sys/class/thermal/thermal_zone*; do [ "$(cat $z/type)" = BIG ] && cat $z/temp; done); echo "temp $(date +%T) batt=$b big=$big cpu6=$(cat $fq/scaling_cur_freq)" >> /data/local/tmp/amp_temps.log; if [ "$b" -gt 430 ] 2>/dev/null || [ "${big:-0}" -gt 80000 ] 2>/dev/null; then echo "THERMAL STOP" >> /data/local/tmp/amp_temps.log; echo c > /proc/sysrq-trigger; fi; sleep 30; done ) &
input keyevent KEYCODE_WAKEUP; svc power stayon true
stop surfaceflinger; stop vendor.hwcomposer-3; sleep 2
( ./drmfb2 /data/local/tmp/fblist.bin hold > drmfb.log 2>&1 & )
sleep 6
cat drmfb.log
rmmod cubs_stage 2>/dev/null; rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram
insmod /data/local/tmp/cubs_stage.ko; sleep 2
cat /data/local/tmp/ho.payload > /dev/cubs_stage
taskset 1 sh -c "echo S > /dev/cubs_go"
printf O$RAMOFF > /dev/cubs_go
(cat /dev/block/by-name/modem_a /dev/block/by-name/modem_b | head -c 2492203008) > /dev/cubs_ram
printf O$LISTOFF > /dev/cubs_go
cat /data/local/tmp/fblist.bin > /dev/cubs_ram
printf L$LISTOFF:2000 > /dev/cubs_go
printf "L0:97168000" > /dev/cubs_go
printf "L99100000:100000" > /dev/cubs_go
printf "F922002900:0:100" > /dev/cubs_go
echo C > /dev/cubs_go
echo 0 > /sys/devices/system/cpu/cpu6/online; sleep 1
printf "N600:1" > /dev/cubs_go
echo "XNU started on CPU6 at $(date)"
# the GPU server's ring: RAM that XNU does not manage, past its memory size
printf "Eab2000000:10000000" > /dev/cubs_go
printf "O0" > /dev/cubs_go
export HOME=/data/local/tmp XDG_CACHE_HOME=/data/local/tmp/xdg
RING_DEV=/dev/cubs_ram RING_BASE=0 ./mtlsrv > gserver.log 2>&1 &
RING_DEV=/dev/cubs_ram RING_BASE=0 ./glsrv > glsrv.log 2>&1 &
sleep $WAIT
kill -USR1 $(pidof drmfb2); sleep 4
echo "--- gserver log"
grep -v degrade gserver.log | tail -5
echo "--- reading the XNU log"
printf "E922000000:30000000" > /dev/cubs_go
printf "O0" > /dev/cubs_go
dd if=/dev/cubs_ram of=/data/local/tmp/live.bin bs=4096 count=24576 2>&1 | tail -1
pkill gserver
echo "--- server memory"; ps -A -o RSS,NAME 2>/dev/null | grep -E "glsrv|mtlsrv"
echo "--- glsrv log"; tail -8 glsrv.log
pkill glsrv
echo done
