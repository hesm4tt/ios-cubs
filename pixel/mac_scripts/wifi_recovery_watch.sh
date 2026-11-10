#!/bin/bash
export PATH=$PATH:/opt/homebrew/bin
for i in $(seq 1 180); do
  state=$(perl -e 'alarm 8; exec @ARGV' adb get-state 2>/dev/null || true)
  if [ "$state" = device ]; then
    boot=$(perl -e 'alarm 8; exec @ARGV' adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
    if [ "$boot" = 1 ]; then
      perl -e 'alarm 30; exec @ARGV' adb shell "echo 'D=/data/local/ios; rm -f \$D/boot_ios \$D/smp \$D/cam \$D/snd \$D/camid \$D/camdelay \$D/noring \$D/cpu6_khz; if [ -f \$D/ios_start.pre-wifistatus ]; then cp \$D/ios_start.pre-wifistatus \$D/ios_start.sh; chmod 755 \$D/ios_start.sh; fi; cp \$D/ho.payload.prod \$D/ho.payload; sync; if pidof drmfb2 >/dev/null; then echo ios-still-active-rebooting; sync; reboot; else echo android-clean; fi' | /data/adb/ksu/bin/ksud debug su" && exit 0
    fi
  fi
  sleep 5
done
echo device-unavailable-after-recovery-window
exit 1
