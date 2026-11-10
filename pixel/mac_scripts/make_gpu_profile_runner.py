from pathlib import Path

s = Path('/tmp/run_cubs_battery_test.sh').read_text()
replacements = {
    '/tmp/wifiscansrv /tmp/battsrv-ios /data/local/tmp/':
        '/tmp/wifiscansrv /tmp/battsrv-ios /tmp/glsrv-profile /data/local/tmp/',
    '/data/local/tmp/wifiscansrv /data/local/tmp/battsrv-ios && mv':
        '/data/local/tmp/wifiscansrv /data/local/tmp/battsrv-ios /data/local/tmp/glsrv-profile && mv',
    "battery='[ -x $D/battsrv ]": """gpu='RING_DEV=/dev/cubs_ram RING_BASE=0 ./glsrv > glsrv.log 2>&1 &'
assert s.count(gpu)==1
s=s.replace(gpu,'RING_DEV=/dev/cubs_ram RING_BASE=0 /data/local/tmp/glsrv-profile > glsrv.log 2>&1 &')
battery='[ -x $D/battsrv ]""",
    '/data/local/tmp/cubsscan-launcher.sh /data/local/tmp/battsrv-ios; sync':
        '/data/local/tmp/cubsscan-launcher.sh /data/local/tmp/battsrv-ios /data/local/tmp/glsrv-profile; sync',
}
for old, new in replacements.items():
    assert s.count(old)==1, old
    s=s.replace(old,new)
Path('/tmp/run_cubs_gpu_profile.sh').write_text(s)
image = Path('/tmp/build_battery_test_image.sh').read_text()
old='/redwood/bin/rwtouch wait 80'
assert image.count(old)==1
image=image.replace(old, old+' swipe 0.5 0.985 0.5 0.3 250 wait 8 swipe 0.85 0.5 0.15 0.5 300 wait 2 swipe 0.15 0.5 0.85 0.5 300')
image=image.replace('root_cubsbatt_test.apfs','root_cubsgpu_profile.apfs')
Path('/tmp/build_gpu_profile_image.sh').write_text(image)
print('gpu-profile-runner-generated')
