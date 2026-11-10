#!/bin/bash
set -euo pipefail
U="$HOME/unixnu-pixel11/hackios-upstream"
S="$U/xnu-src/xnu-8796.121.2/osfmk/arm64/loader_return.c"
B=$(mktemp -d /tmp/cubs-wallpaper-kernel.XXXXXX)
NAME="${PAYLOAD_NAME:-cubswallnormal}"
case "$NAME" in *[!a-zA-Z0-9_]*|'') echo invalid-payload-name; exit 1;; esac
cp -p "$S" "$B/loader.c"
cleanup() {
  cp -p "$B/loader.c" "$S"; touch "$S"
  (cd "$U" && bash xnu-build.sh > /tmp/cubs-wallpaper-restored-build.log 2>&1) || :
  cmp -s "$S" "$B/loader.c" || echo loader-restore-failed
}
trap cleanup EXIT
ROOT="${ROOT_IMAGE:-$HOME/hopay/root_cubs_wallpaper_normal.apfs}" ADT="$HOME/hopay/ho.adt" \
  bash "$HOME/mac_build.sh" "$NAME.payload" \
  "debug=0x8 keepsyms=1 cpus=1 rd=md0 loader_return_after=100000 cubs_blit=3 cubs_touch=1 cubs_touch_div=16 gl=1 cubs_net=1 ${BOOT_EXTRA-cubs_shot=1}" > /tmp/cubswallnormal-build.log 2>&1
if grep -qE '(^|[[:space:]])(fatal )?error:' "$HOME/xnu_build_blit.log"; then echo kernel-source-error; exit 1; fi
cd "$HOME/pcwork"
python3 bootreg.py "$HOME/hopay/$NAME.payload" "hopay2/${NAME}r.payload" 0x600 >/dev/null
PAYLOAD_NAME="$NAME" python3 - <<'PY'
import os,struct
p=os.path.expanduser('~/hopay/'+os.environ['PAYLOAD_NAME']+'.payload')
d=open(p,'rb').read(80)
vb,_,_,_,end,_,mem=struct.unpack_from('<7Q',d,16)
ram=end-vb-((2492203008+0x3fff)&~0x3fff)
lst=mem-0x100000
assert ram>0 and ram%0x4000==0 and lst==0x17fe00000
open('/tmp/'+os.environ['PAYLOAD_NAME']+'-offsets','w').write('%x %x\n'%(ram,lst))
print('one-core wallpaper payload offsets',hex(ram),hex(lst))
PY
