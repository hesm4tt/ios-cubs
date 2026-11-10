#!/bin/bash
# usage: run_img_win.sh <img> <tag> [waitsec]  - Windows version of run_img_mac.sh (phone attached to this PC)
export MSYS_NO_PATHCONV=1
IMG=$1; TAG=$2; WAIT=${3:-1500}
ser=<adb-serial>
out=cubs-images/run-$TAG; mkdir -p $out
up() { adb -s $ser shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | grep -q '^1'; }
up || { echo "phone not in Android"; exit 2; }
echo "start $(date +%T) image $(sha256sum $IMG | cut -d' ' -f1)"
adb -s $ser reboot bootloader
for i in $(seq 60); do fastboot devices | grep -q $ser && break; sleep 2; done
fastboot devices | grep -q $ser || { echo "no fastboot"; exit 3; }
fastboot -s $ser getvar product 2>&1 | grep -q 'product: cubs' || { fastboot -s $ser reboot; echo "unexpected product"; exit 4; }
fastboot -s $ser boot $IMG 2>&1 | tee $out/fastboot-boot.log | tail -3
end=$((SECONDS+WAIT)); upok=0
while [ $SECONDS -lt $end ]; do
  if up; then upok=1; break; fi
  fastboot devices | grep -q $ser && fastboot -s $ser reboot >/dev/null 2>&1
  sleep 5
done
echo "android back: $upok at $(date +%T)"
[ $upok = 1 ] || exit 5
adb -s $ser shell "grep -a 'Reboot reason' /sys/fs/pstore/console-ramoops-0 | tail -3" | tee $out/cookie.txt
adb -s $ser shell "/data/adb/ksu/bin/ksud debug su" <<< "dd if=/dev/block/by-name/modem_b bs=4096 skip=295690 count=400 of=/data/local/tmp/ufslog.bin 2>/dev/null" >/dev/null
MSYS_NO_PATHCONV=1 adb -s $ser pull /data/local/tmp/ufslog.bin $out/ufslog.bin >/dev/null
python - $out/ufslog.bin $out/kernel-log.txt <<'PY'
import sys,struct
d=open(sys.argv[1],'rb').read()
if d[:8]!=b'CUBSLOG1': print('no log header'); sys.exit()
ln,b,st=struct.unpack('<III',d[8:20]); open(sys.argv[2],'wb').write(d[4096:4096+ln]); print('log state',st,'bytes',ln)
PY
echo DONE
