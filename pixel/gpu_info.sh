dmesg | grep -a -i -E "pvr|rgx|powervr|imagination|gpu" | head -12 | cut -c1-200
ls /sys/devices/platform | grep -i -E "gpu|pvr|rgx|mali|img" | head
for f in /sys/devices/platform/*gpu* /sys/devices/platform/*pvr*; do [ -e "$f" ] && echo "$f: $(ls $f | head -8 | tr '\n' ' ')"; done 2>/dev/null | head -6
cat /sys/class/misc/pvr*/uevent 2>/dev/null | head
getprop ro.hardware.vulkan; getprop ro.hardware.egl
ls /vendor/lib64/hw 2>/dev/null | grep -i -E "vulkan|gralloc|pvr" | head
ls /vendor/lib64 2>/dev/null | grep -i -E "pvr|vulkan|img|powervr" | head -10
