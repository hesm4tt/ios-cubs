#!/system/bin/sh
# Software "replug": after a reset the host sometimes never enumerates adb until the cable is replugged
# (UDC state stays "not attached"). Toggle the role switch data path while the UDC is not configured.
L=/data/local/tmp/usbkick.log
D=/sys/devices/platform/goog_usb_role_sw/disable_usb_data
while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done
n=0
while [ $n -lt 60 ]; do
  sleep 15
  n=$((n+1))
  s=$(cat /sys/class/udc/*/state)
  if [ "$s" != "configured" ]; then
    echo "$(date) toggle n=$n state=$s" >> $L
    echo 1 > $D; sleep 3; echo 0 > $D
  fi
done
