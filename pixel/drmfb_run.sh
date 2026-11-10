chmod 755 /data/local/tmp/drmfb
stop surfaceflinger; stop vendor.hwcomposer-3; sleep 2
HZ=$(cat /data/local/tmp/want_hz 2>/dev/null)
( /data/local/tmp/drmfb /data/local/tmp/fblist.bin hold $HZ > /data/local/tmp/drmfb.log 2>&1 & )
sleep 6
cat /data/local/tmp/drmfb.log
