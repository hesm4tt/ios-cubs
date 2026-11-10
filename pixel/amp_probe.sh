rmmod cubs_stage 2>/dev/null; rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram
insmod /data/local/tmp/cubs_stage.ko; sleep 2
printf "E922000000:17ff00000" > /dev/cubs_go
printf "A600" > /dev/cubs_go
printf "H2900:12" > /dev/cubs_go
printf "H1000:8" > /dev/cubs_go
dmesg | grep -a -E "affinity|H[|]" | tail -8 | cut -c1-170
