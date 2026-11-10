# usage: fbgrab.sh PA_HEX ROWBYTES HEIGHT  -> /data/local/tmp/fb.bin (the iOS framebuffer from XNU's memory)
PA=$1
printf "E${PA}:B00000" > /dev/cubs_go
printf O0 > /dev/cubs_go
dd if=/dev/cubs_ram of=/data/local/tmp/fb.bin bs=1M count=11 2>/dev/null
printf Eab2000000:10000000 > /dev/cubs_go
printf O0 > /dev/cubs_go
