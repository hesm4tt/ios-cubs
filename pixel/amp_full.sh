rmmod google_ehld_coreinstr 2>/dev/null
fq=/sys/devices/system/cpu/cpufreq/policy6
echo $(cat $fq/cpuinfo_max_freq) > $fq/scaling_max_freq; echo $(cat $fq/cpuinfo_max_freq) > $fq/scaling_min_freq
rmmod cubs_stage 2>/dev/null; rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram
insmod /data/local/tmp/cubs_stage.ko; sleep 2
cat /data/local/tmp/ho.payload > /dev/cubs_stage
taskset 1 sh -c "echo S > /dev/cubs_go"
printf O28a8000 > /dev/cubs_go
(cat /dev/block/by-name/modem_a /dev/block/by-name/modem_b | head -c 2492203008) > /dev/cubs_ram
printf "L0:97168000" > /dev/cubs_go
printf "F922002900:0:100" > /dev/cubs_go
echo C > /dev/cubs_go
echo 0 > /sys/devices/system/cpu/cpu6/online; sleep 1
printf "N600:1" > /dev/cubs_go
for i in 1 2 3 4 5 6; do
  sleep 10
  echo "--- t=$((i*10)) s"
  printf "A600" > /dev/cubs_go
  echo V > /dev/cubs_go
  printf "H1bf9208:4" > /dev/cubs_go
done
printf "D1d189f8:4000" > /dev/cubs_go
dmesg | grep -a -E "cubs_stage: (affinity|amp)|H[|] 1bf9|X[|]" | tail -60 | cut -c1-170
