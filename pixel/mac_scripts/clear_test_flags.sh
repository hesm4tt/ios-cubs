export PATH=$PATH:/opt/homebrew/bin
adb shell "echo 'rm -f /data/local/ios/boot_ios /data/local/ios/cam /data/local/ios/camid /data/local/ios/camdelay /data/local/ios/noring /data/local/ios/smp /data/local/ios/snd /data/local/ios/cpu6_khz; cmp /data/local/ios/ho.payload /data/local/ios/ho.payload.prod && echo payload-is-prod; ls /data/local/ios/boot_ios /data/local/ios/cam /data/local/ios/camid /data/local/ios/camdelay /data/local/ios/noring /data/local/ios/smp /data/local/ios/snd /data/local/ios/cpu6_khz 2>/dev/null' | /data/adb/ksu/bin/ksud debug su"
adb shell getprop sys.boot_completed
