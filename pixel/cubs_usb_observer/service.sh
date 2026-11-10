#!/system/bin/sh
# KernelSU late-start service is nonblocking; the observer stops after ten minutes.
MODDIR=${0%/*}
sh "$MODDIR/observe.sh" /data/adb/cubs-usb-observer 60 10 </dev/null >/dev/null 2>&1 &
