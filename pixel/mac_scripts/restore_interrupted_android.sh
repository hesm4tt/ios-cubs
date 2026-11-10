#!/system/bin/sh
set -e
D=/data/local/ios
[ -f "$D/ios_start.pre-wifistatus" ]
[ -f "$D/ho.payload.prod" ]
rm -f "$D/boot_ios" "$D/smp" "$D/cam" "$D/snd" "$D/camid" "$D/camdelay" "$D/noring" "$D/cpu6_khz"
cp "$D/ios_start.pre-wifistatus" "$D/ios_start.sh"
chmod 755 "$D/ios_start.sh"
cp "$D/ho.payload.prod" "$D/ho.payload"
cmp "$D/ho.payload" "$D/ho.payload.prod"
sync
echo restored-rebooting
reboot
