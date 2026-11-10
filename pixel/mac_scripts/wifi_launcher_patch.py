#!/usr/bin/env python3
"""wifi_launcher_patch.py LAUNCHER: add the Wi-Fi status/scan bridge to the phone launcher (ios_start.sh), under the flag file /data/local/ios/wifi.

  before `stop surfaceflinger` (the display must still be up for the foreground service): start com.cubs.cam's WifiStatusService with scans on;
  after netsrv: start wifisrv and wifiscansrv, which forward the service's Wi-Fi snapshots into the shared ring (they check the app's uid).
Needs the payload built with cubs_wifi=1 (build_wifi_payload.sh) and the companion APK that has WifiStatusService installed.
"""
import sys

p = sys.argv[1]
s = open(p).read()
stop = 'stop surfaceflinger; stop vendor.hwcomposer-3; sleep 2'
net = '[ -x $D/netsrv ] && sh $D/netsrv.sh &'
assert s.count(stop) == 1 and s.count(net) == 1, 'launcher layout changed'
assert 'WifiStatusService' not in s, 'already patched'
CR = chr(92) + 'r'
start = (
    'if [ -f $D/wifi ]; then\n'
    "\tWIFI_APP_UID=$(cmd package list packages -U com.cubs.cam | sed -n 's/.*uid://p' | tr -d '" + CR + "')\n"
    '\tcase "$WIFI_APP_UID" in \'\'|*[!0-9]*) WIFI_APP_UID= ;; esac\n'
    '\tif [ -n "$WIFI_APP_UID" ]; then\n'
    '\t\tam start-foreground-service --user 0 -n com.cubs.cam/com.cubs.cam.WifiStatusService --ez scans true > $D/wifiapp.log 2>&1\n'
    '\t\tsleep 2\n'
    '\tfi\n'
    'fi\n'
)
daemons = (
    '\nif [ -f $D/wifi ] && [ -n "$WIFI_APP_UID" ]; then\n'
    '\t[ -x $D/wifisrv ] && ( $D/wifisrv "$WIFI_APP_UID" > $D/wifisrv.log 2>&1 & )\n'
    '\t[ -x $D/wifiscansrv ] && ( $D/wifiscansrv "$WIFI_APP_UID" > $D/wifiscansrv.log 2>&1 & )\n'
    'fi'
)
s = s.replace(stop, start + stop).replace(net, net + daemons)
open(p, 'w', newline='\n').write(s)
print('wifi block added')
