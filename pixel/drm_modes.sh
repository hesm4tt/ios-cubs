chmod 755 /data/local/tmp/drmfb
stop surfaceflinger; stop vendor.hwcomposer-3; sleep 2
/data/local/tmp/drmfb /data/local/tmp/fb_probe.bin 2>&1 | head -30
start surfaceflinger; start vendor.hwcomposer-3
