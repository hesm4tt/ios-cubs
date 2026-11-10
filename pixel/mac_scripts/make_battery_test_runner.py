"""Make a private battery runner from the already-supervised scan runner."""
from pathlib import Path

s = Path('/tmp/run_cubs_scan_ios_test.sh').read_text()
replacements = {
    '/tmp/cubsscan1-offsets': '/tmp/cubsbatt-test-offsets',
    '$HOME/pcwork/hopay2/cubsscan1r.payload': '$HOME/pcwork/hopay2/cubsbatt-test.payload',
    'adb push /tmp/cubsscan-launcher.sh /tmp/wifisrv /tmp/wifiscansrv /data/local/tmp/':
        'adb push /tmp/cubsscan-launcher.sh /tmp/wifisrv /tmp/wifiscansrv /tmp/battsrv-ios /data/local/tmp/',
    'chmod 755 /data/local/ios/ios_start.cubsscan.tmp /data/local/tmp/wifisrv /data/local/tmp/wifiscansrv':
        'chmod 755 /data/local/ios/ios_start.cubsscan.tmp /data/local/tmp/wifisrv /data/local/tmp/wifiscansrv /data/local/tmp/battsrv-ios',
    "s=s.replace(c,c+'''": """battery='[ -x $D/battsrv ] && ( $D/battsrv > $D/battsrv.log 2>&1 & )'
assert s.count(battery)==1
s=s.replace(battery,'/data/local/tmp/battsrv-ios > $D/cubsscan-battsrv.log 2>&1 &')
s=s.replace(c,c+'''""",
    '/data/local/tmp/cubsscan-launcher.sh; sync': '/data/local/tmp/cubsscan-launcher.sh /data/local/tmp/battsrv-ios; sync',
}
for old,new in replacements.items():
    assert s.count(old)==1, old
    s=s.replace(old,new)
Path('/tmp/run_cubs_battery_test.sh').write_text(s)
print('battery-runner-generated')
