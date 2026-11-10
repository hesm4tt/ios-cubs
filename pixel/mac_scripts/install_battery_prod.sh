#!/bin/bash
set -eu
export PATH=$PATH:/opt/homebrew/bin
python3 - <<'PY'
import struct
p='$HOME/hopay/prodbatt.payload'
d=open(p,'rb').read(80)
vb,_,_,_,ke,_,mem=struct.unpack_from('<7Q',d,16)
ram=ke-vb-((2492203008+0x3fff)&~0x3fff)
assert ram == 0x28b4000 and mem-0x100000 == 0x17fe00000, (hex(ram),hex(mem-0x100000))
print('payload offsets match launcher')
PY
adb push "$HOME/pcwork/hopay2/prodbattr.payload" /data/local/tmp/prodbatt.payload >/dev/null
adb push /tmp/battsrv /data/local/tmp/battsrv.new >/dev/null
adb push /tmp/ios_start.sh /data/local/tmp/ios_start.new >/dev/null
adb shell "echo 'set -e; D=/data/local/ios; cp \$D/ho.payload.prod \$D/ho.payload.pre-battery; cp \$D/ios_start.sh \$D/ios_start.pre-battery-prod; cp /data/local/tmp/battsrv.new \$D/battsrv; chmod 755 \$D/battsrv; cp /data/local/tmp/ios_start.new \$D/ios_start.sh; chmod 755 \$D/ios_start.sh; cp /data/local/tmp/prodbatt.payload \$D/ho.payload.prod; cp /data/local/tmp/prodbatt.payload \$D/ho.payload; sync; cmp \$D/ho.payload \$D/ho.payload.prod; echo battery-production-installed' | /data/adb/ksu/bin/ksud debug su"
