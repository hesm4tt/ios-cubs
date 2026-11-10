rmmod cubs_stage 2>/dev/null; rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram
insmod /data/local/tmp/cubs_stage.ko; sleep 2
for m in 1 4 40; do echo "cpumask $m"; taskset $m sh -c "echo I > /dev/cubs_go"; done
dmesg | grep -a "ID[|]" | tail -6 | cut -c1-200
