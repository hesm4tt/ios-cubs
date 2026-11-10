ls /sys/devices/virtual/goog_touch_interface/ 2>&1 | head
for d in /sys/devices/virtual/goog_touch_interface/*; do echo "== $d"; ls $d | head -60; done 2>&1 | head -90
ls /sys/class/input | head; for i in /sys/class/input/input*; do echo "$i: $(cat $i/name)"; done | head -20
ls /sys/kernel/debug | grep -i -E "goog|touch|syna|gti" | head
