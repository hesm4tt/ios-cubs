#!/system/bin/sh
cp /data/local/ios/ios_start.pre-logtest /data/local/ios/ios_start.recover.tmp && chmod 755 /data/local/ios/ios_start.recover.tmp && mv -f /data/local/ios/ios_start.recover.tmp /data/local/ios/ios_start.sh
rm -f /data/local/ios/boot_ios /data/local/ios/smp
sync
reboot
