#!/bin/bash
# inst_wifi.sh: install the production payload with the Wi-Fi status/scan bridge (cubswifi = production jb image + cubs_wifi=1), run on the Mac with the
# phone in Android. Needs: the companion APK with WifiStatusService installed (done: com.cubs.cam candidate), wifisrv/wifiscansrv in /data/local/ios.
# Changes on the phone (/data/local/ios): ho.payload + ho.payload.prod (backup ho.payload.pre-wifi), env.sh (RAMOFF; backup env.sh.pre-wifi),
# ios_start.sh (backup ios_start.pre-wifi2: the flag `wifi` starts the status service and the two daemons), flag `wifi`.
# Rollback on the phone:  cd /data/local/ios; cp ho.payload.pre-wifi ho.payload.prod; cp ho.payload.pre-wifi ho.payload; cp env.sh.pre-wifi env.sh; cp ios_start.pre-wifi2 ios_start.sh; rm -f wifi
# (or just `rm wifi` to run without the bridge: iOS then sees plain Ethernet; the payload still has cubs_wifi=1 but gets no status).
set -eu
export PATH="$PATH:/opt/homebrew/bin"
NAME=${NAME:-cubswifi}
read -r RAMOFF LISTOFF < "/tmp/$NAME-offsets"
[ "$LISTOFF" = 17fe00000 ] || { echo "unexpected LISTOFF $LISTOFF"; exit 1; }
[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ] || { echo android-not-ready; exit 1; }
rootsh() { printf '%s\n' "$1" | adb shell /data/adb/ksu/bin/ksud debug su; }
rootsh 'D=/data/local/ios; cmp $D/ho.payload $D/ho.payload.prod || exit 1; test -x $D/wifisrv && test -x $D/wifiscansrv || { echo missing-daemons; exit 1; }; for f in boot_ios smp cam camid camdelay noring cpu6_khz wifi ho.payload.pre-wifi ios_start.pre-wifi2 env.sh.pre-wifi; do test ! -e $D/$f || { echo leftover $f; exit 1; }; done; echo preflight-ok' | grep preflight-ok >/dev/null
adb push "$HOME/pcwork/hopay2/${NAME}r.payload" /data/local/tmp/prodwifi.payload >/dev/null
adb pull /data/local/ios/ios_start.sh /tmp/prodwifi-launcher.sh >/dev/null
python3 "$HOME/wifi_launcher_patch.py" /tmp/prodwifi-launcher.sh
adb push /tmp/prodwifi-launcher.sh /data/local/tmp/prodwifi-launcher.sh >/dev/null
rootsh "D=/data/local/ios; set -e; cp \$D/ho.payload.prod \$D/ho.payload.pre-wifi; cp \$D/env.sh \$D/env.sh.pre-wifi; cp \$D/ios_start.sh \$D/ios_start.pre-wifi2; cp /data/local/tmp/prodwifi.payload \$D/ho.payload.new-wifi; cp \$D/ho.payload.new-wifi \$D/ho.payload.prod.new-wifi; mv -f \$D/ho.payload.prod.new-wifi \$D/ho.payload.prod; mv -f \$D/ho.payload.new-wifi \$D/ho.payload; printf 'export RAMOFF=$RAMOFF\nexport LISTOFF=$LISTOFF\n' > \$D/env.sh.new; mv -f \$D/env.sh.new \$D/env.sh; cp /data/local/tmp/prodwifi-launcher.sh \$D/ios_start.new; chmod 755 \$D/ios_start.new; mv -f \$D/ios_start.new \$D/ios_start.sh; touch \$D/wifi; rm -f /data/local/tmp/prodwifi.payload /data/local/tmp/prodwifi-launcher.sh; sync; cmp \$D/ho.payload \$D/ho.payload.prod && cat \$D/env.sh && echo wifi-production-installed"
