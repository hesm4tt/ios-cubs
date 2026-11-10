#!/system/bin/sh
# usbmux_gadget.sh apply|revert|status  (root, on the phone, in Android; v2: the gadget HAL is stopped first, because it resets the gadget behind our back): makes the USB gadget an "iPhone" for the Mac: Apple's vendor/product id and
# a usbmux function (FunctionFS, served by usbmuxdev) next to adb in the same configuration. SAFE BY DESIGN: apply starts a watchdog that reverts
# everything after 150 s unless /data/local/tmp/usbmux.keep exists (v2: by a REBOOT, which brings the stock gadget and the HAL back), so that a bad gadget can never strand adb for long.
# Rollback by hand:  sh /data/local/tmp/usbmux_gadget.sh revert
G=/config/usb_gadget/g1
UDC_NAME=a210000.dwc3
SAVE=/data/local/tmp/usbmux.orig
FFS=/dev/usb-ffs/usbmux
BIN=/data/local/ios/usbmuxdev
LOG=/data/local/ios/usbmuxdev.log
SERIAL=${USBMUX_SERIAL:-00008140001A2B3C4D5E6F70}

rebind() { echo "" > $G/UDC; sleep 1; echo $UDC_NAME > $G/UDC; }

case "$1" in
apply)
	if [ ! -f $SAVE ]; then
		{ echo "vid=$(cat $G/idVendor)"; echo "pid=$(cat $G/idProduct)"; echo "ser=$(cat $G/strings/0x409/serialnumber)"
		  echo "prod=$(cat $G/strings/0x409/product)"; echo "man=$(cat $G/strings/0x409/manufacturer)"; } > $SAVE
	fi
	rm -f /data/local/tmp/usbmux.keep
	stop vendor.usb-gadget-hal
	sleep 1
	mkdir -p $G/functions/ffs.usbmux $FFS
	mountpoint -q $FFS || mount -t functionfs usbmux $FFS || { echo "mount failed"; exit 1; }
	pkill usbmuxdev 2>/dev/null
	$BIN $FFS > $LOG 2>&1 &
	sleep 1
	echo "" > $G/UDC
	echo 0x05ac > $G/idVendor
	echo 0x12a8 > $G/idProduct
	echo "$SERIAL" > $G/strings/0x409/serialnumber
	echo "iPhone" > $G/strings/0x409/product
	echo "Apple Inc." > $G/strings/0x409/manufacturer
	[ -e $G/configs/b.1/function9 ] || ln -s $G/functions/ffs.usbmux $G/configs/b.1/function9
	echo $UDC_NAME > $G/UDC
	echo "applied, HAL stopped (revert + reboot in 150 s unless /data/local/tmp/usbmux.keep exists)"
	( sleep 150; [ -f /data/local/tmp/usbmux.keep ] || { sh /data/local/tmp/usbmux_gadget.sh revert; sleep 5; reboot; } ) > /dev/null 2>&1 &
	;;
revert)
	echo "" > $G/UDC
	rm -f $G/configs/b.1/function9
	if [ -f $SAVE ]; then
		. $SAVE
		echo "$vid" > $G/idVendor; echo "$pid" > $G/idProduct
		echo "$ser" > $G/strings/0x409/serialnumber; echo "$prod" > $G/strings/0x409/product; echo "$man" > $G/strings/0x409/manufacturer
	fi
	pkill usbmuxdev 2>/dev/null
	umount $FFS 2>/dev/null
	rmdir $G/functions/ffs.usbmux 2>/dev/null
	echo $UDC_NAME > $G/UDC
	start vendor.usb-gadget-hal
	echo reverted
	;;
status)
	echo "vid=$(cat $G/idVendor) pid=$(cat $G/idProduct) udc=$(cat $G/UDC) serial=$(cat $G/strings/0x409/serialnumber)"
	ls $G/configs/b.1
	pgrep -l usbmuxdev
	tail -5 $LOG 2>/dev/null
	;;
*)
	echo "usage: usbmux_gadget.sh apply|revert|status"
	;;
esac
