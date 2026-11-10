#!/system/bin/sh
# Read-only USB state, no serials, addresses, subscriber data, or USB control.
set -u
dir=$1 count=$2 interval=$3
umask 077
mkdir -p "$dir" || exit 1
chmod 700 "$dir" || exit 1
[ ! -f "$dir/current.log" ] || mv -f "$dir/current.log" "$dir/previous.log"
i=0
while [ "$i" -lt "$count" ]; do
    uptime=$(cut -d ' ' -f 1 /proc/uptime)
    usb_state=$(getprop sys.usb.state)
    usb_config=$(getprop sys.usb.config)
    ffs=$(getprop sys.usb.ffs.ready)
    adbd=$(getprop init.svc.adbd)
    boot=$(getprop sys.boot_completed)
    udc=unavailable
    for f in /sys/class/udc/*/state; do
        if [ -r "$f" ]; then udc=$(cat "$f" 2>/dev/null); break; fi
    done
    printf 'uptime=%s udc=%s usb_state=%s usb_config=%s ffs=%s adbd=%s boot=%s\n' \
        "$uptime" "$udc" "$usb_state" "$usb_config" "$ffs" "$adbd" "$boot" >> "$dir/current.log"
    i=$((i+1))
    [ "$i" -ge "$count" ] || sleep "$interval"
done
