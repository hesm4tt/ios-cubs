#!/bin/bash
set -eu
export PATH=$PATH:/opt/homebrew/bin
python3 - <<'PY'
import struct
p='$HOME/hopay/prodposter.payload'; d=open(p,'rb').read(80)
vb,_,_,_,ke,_,mem=struct.unpack_from('<7Q',d,16)
assert ke-vb-((2492203008+0x3fff)&~0x3fff)==0x28b4000 and mem-0x100000==0x17fe00000
print('payload offsets match')
PY
adb push "$HOME/pcwork/hopay2/prodposterr.payload" /data/local/tmp/prodposter.payload >/dev/null
adb shell "echo 'set -e; D=/data/local/ios; cp \$D/ho.payload.prod \$D/ho.payload.pre-poster; cp /data/local/tmp/prodposter.payload \$D/ho.payload.prod; cp /data/local/tmp/prodposter.payload \$D/ho.payload; sync; cmp \$D/ho.payload \$D/ho.payload.prod; echo wallpaper-production-installed' | /data/adb/ksu/bin/ksud debug su"
