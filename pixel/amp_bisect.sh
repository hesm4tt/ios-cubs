rmmod google_ehld_coreinstr 2>/dev/null
for CP in 1 2 3 4 5 6; do
  rmmod cubs_stage 2>/dev/null; rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram
  insmod /data/local/tmp/cubs_stage.ko; sleep 1
  cat /data/local/tmp/ho.payload > /dev/cubs_stage
  printf "P$CP" > /dev/cubs_go
  taskset 1 sh -c "echo S > /dev/cubs_go"
  printf "L0:2000000" > /dev/cubs_go
  echo C > /dev/cubs_go
  echo 0 > /sys/devices/system/cpu/cpu6/online 2>/dev/null; sleep 1
  printf "N600:1" > /dev/cubs_go
  sleep 3
  printf "A600" > /dev/cubs_go
  echo V > /dev/cubs_go
  dmesg | grep -a -E "cubs_stage: (affinity|amp)" | tail -2 | sed "s/^/CP=$CP /" | cut -c1-190
  aff=$(dmesg | grep -a "cubs_stage: affinity" | tail -1 | sed 's/.*= //')
  [ "$aff" = "0" ] && { echo "CP=$CP NOT reached (core still on): stop"; break; }
  echo 1 > /sys/devices/system/cpu/cpu6/online 2>/dev/null
done
