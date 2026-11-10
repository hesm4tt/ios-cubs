from pathlib import Path

s=Path('/tmp/run_wallpaper_normal_test.sh').read_text()
replacements={
 '/tmp/cubswallnormal-offsets':'/tmp/cubswifi1-offsets',
 '[ "$RAMOFF" = 28b4000 ]':'[ "$RAMOFF" = 28c8000 ]',
 '$HOME/pcwork/hopay2/cubswallnormalr.payload':'$HOME/pcwork/hopay2/cubswifi1r.payload',
 'adb push /tmp/cubswall-launcher.sh /data/local/tmp/cubswall-launcher.sh >/dev/null || fail launcher-push':
 'adb push /tmp/cubswall-launcher.sh /tmp/wifisrv /tmp/wifiscansrv /data/local/tmp/ >/dev/null || fail launcher-push\nrootsh \'chmod 755 /data/local/tmp/wifisrv /data/local/tmp/wifiscansrv\' || fail bridge-permissions',
 "s=s.replace(a,a+watch)": """s=s.replace(a,a+watch)
b='. $D/env.sh'
assert s.count(b)==1
s=s.replace(b,b+'\\nRAMOFF=28c8000')
stop='stop surfaceflinger; stop vendor.hwcomposer-3; sleep 2'
assert s.count(stop)==1
s=s.replace(stop,'''WIFI_APP_UID=$(cmd package list packages -U com.cubs.cam | sed -n 's/.*uid://p' | tr -d '\\\\r')
case "$WIFI_APP_UID" in ''|*[!0-9]*) echo 'wifi app uid unavailable'; exit 1;; esac
am start-foreground-service --user 0 -n com.cubs.cam/com.cubs.cam.WifiStatusService --ez scans true > $D/cubswall-wifi-app.log 2>&1
sleep 2
'''+stop)
net='[ -x $D/netsrv ] && sh $D/netsrv.sh &'
assert s.count(net)==1
s=s.replace(net,net+'''\\n/data/local/tmp/wifisrv "$WIFI_APP_UID" > $D/cubswall-wifi-status.log 2>&1 &
/data/local/tmp/wifiscansrv "$WIFI_APP_UID" > $D/cubswall-wifi-scan.log 2>&1 &''')""",
 '/data/local/tmp/cubswall-launcher.sh /data/local/tmp/cubswall.payload; sync':
 '/data/local/tmp/cubswall-launcher.sh /data/local/tmp/cubswall.payload /data/local/tmp/wifisrv /data/local/tmp/wifiscansrv; sync',
}
for old,new in replacements.items():
    assert s.count(old)==1, old
    s=s.replace(old,new)
Path('/tmp/run_wifi_onecore.sh').write_text(s)
print('one-core-wifi-runner-generated')
