rmmod cubs_stage 2>/dev/null; rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram
insmod /data/local/tmp/cubs_stage.ko; sleep 2
printf "E922000000:17ff00000" > /dev/cubs_go
printf "A600" > /dev/cubs_go
printf "G0:10000000" > /dev/cubs_go
printf "G10000000:30000000" > /dev/cubs_go
printf "H17f400000:8" > /dev/cubs_go
dmesg | grep -a -E "affinity|G[|]|H[|] 17f4" | tail -12 | cut -c1-170
