echo "== vmalloc"; grep -E "da2c000|e500000" /proc/vmallocinfo | head
echo "== spi modules"; lsmod | grep -i -E "spi|google" | head; ls /vendor_dlkm/lib/modules 2>/dev/null | grep -i -E "spi|syna|gpio" | head; ls /system_dlkm/lib/modules 2>/dev/null | grep -i spi | head
echo "== driver of da2c000"; ls -l /sys/devices/platform/da2c000.spi/driver 2>&1 | head -2; cat /sys/devices/platform/da2c000.spi/power/runtime_status 2>&1; cat /sys/devices/platform/da2c000.spi/power/runtime_suspended_time 2>&1
echo "== tracing"; ls /sys/kernel/tracing/events/rwmmio 2>&1 | head; cat /sys/kernel/tracing/events/rwmmio/rwmmio_write/format 2>&1 | head -20
