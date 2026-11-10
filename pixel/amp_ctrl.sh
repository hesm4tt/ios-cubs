rmmod google_ehld_coreinstr 2>/dev/null
rmmod cubs_stage 2>/dev/null; rm -f /dev/cubs_stage /dev/cubs_go /dev/cubs_ram
insmod /data/local/tmp/cubs_stage.ko; sleep 2
cat /data/local/tmp/ho.payload > /dev/cubs_stage
taskset 1 sh -c "echo S > /dev/cubs_go"
printf "L0:2000000" > /dev/cubs_go
echo C > /dev/cubs_go
echo "--- before start"
for o in 13b0000 1bf9208 1d189f8; do printf "H%s:4" $o > /dev/cubs_go; done
sleep 1
echo "(control: no CPU_ON)"
for i in 1 2 3 4 5 6; do
  sleep 1
  echo "--- t=$i s"
  for o in 13b0000 1bf9208 1c00000; do printf "H%s:4" $o > /dev/cubs_go; done
  echo V > /dev/cubs_go
done
dmesg | grep -a -E "^\[ *[0-9.]+\] (cubs_stage: (CPU_ON|amp)|H[|])" | tail -40 | cut -c1-150
