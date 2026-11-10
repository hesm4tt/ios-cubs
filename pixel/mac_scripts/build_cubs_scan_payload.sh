#!/bin/bash
set -euo pipefail
UP="$HOME/unixnu-pixel11/hackios-upstream"
D="$UP/xnu-src/xnu-8796.121.2/bsd/dev"
S="$UP/xnu-src/xnu-8796.121.2/bsd/sys"
K="$UP/xnu-src/xnu-8796.121.2/BUILD/obj/DEVELOPMENT_ARM64_BCM2837/mach.development.bcm2837"
NAME="${PAYLOAD_NAME:-cubsscan1}"
CPUS="${CPU_COUNT:-3}"
case "$NAME" in *[!a-zA-Z0-9_]*|'') echo invalid-payload-name; exit 1;; esac
case "$CPUS" in 1|3) ;; *) echo unsupported-cpu-count; exit 1;; esac
T=$(mktemp -d /tmp/cubs-scan-buildsrc.XXXXXX)
[ ! -e "$D/redwood_scan_decode.h" ] || { echo header-already-present; exit 1; }
[ ! -e "$D/redwood_join_security.h" ] || { echo join-header-already-present; exit 1; }
cp -p "$D/redwood_cubs_net.c" "$T/net.c"
cp -p "$D/redwood_apple80211.c" "$T/wifi.c"
cp -p "$D/redwood_sta.c" "$T/sta.c"
cp -p "$S/redwood_sta.h" "$T/sta.h"
cleanup() {
  cp -p "$T/net.c" "$D/redwood_cubs_net.c"
  cp -p "$T/wifi.c" "$D/redwood_apple80211.c"
  cp -p "$T/sta.c" "$D/redwood_sta.c"
  cp -p "$T/sta.h" "$S/redwood_sta.h"
  touch "$D/redwood_cubs_net.c" "$D/redwood_apple80211.c" "$D/redwood_sta.c" "$S/redwood_sta.h"
  rm -f "$D/redwood_scan_decode.h"
  rm -f "$D/redwood_join_security.h"
  ( cd "$UP" && bash xnu-build.sh > /tmp/cubsscan-restored-build.log 2>&1 ) || :
  if /opt/homebrew/opt/llvm/bin/llvm-nm "$K" 2>/dev/null | grep _cw_scan_data >/dev/null; then
    echo 'WARNING experimental kernel remains in build tree' >&2
  fi
}
trap cleanup EXIT
cp /tmp/redwood_cubs_net.c "$D/redwood_cubs_net.c"
cp /tmp/redwood_apple80211.c "$D/redwood_apple80211.c"
cp /tmp/redwood_sta.proposed.c "$D/redwood_sta.c"
cp /tmp/redwood_sta.h "$S/redwood_sta.h"
cp /tmp/redwood_scan_decode.h "$D/redwood_scan_decode.h"
cp /tmp/redwood_join_security.h "$D/redwood_join_security.h"
ROOT="${ROOT_IMAGE:-$HOME/hopay/root_wifistatus3.apfs}" ADT="${ADT_PATH:-/tmp/ho_three_experiment.adt}" \
  bash "$HOME/mac_build.sh" "$NAME.payload" "debug=0x8 keepsyms=1 cpus=$CPUS rd=md0 loader_return_after=100000 cubs_blit=3 cubs_touch=1 cubs_touch_div=16 gl=1 cubs_net=1 cubs_wifi=1 cubs_shot=1 ${EXTRA_BOOTARGS:-}" > /tmp/cubsscan-payload-build.log 2>&1
if grep -qE '(^|[[:space:]])(fatal )?error:' "$HOME/xnu_build_blit.log"; then echo kernel-source-error; exit 1; fi
/opt/homebrew/opt/llvm/bin/llvm-nm "$K" 2>/dev/null | grep _cw_scan_data >/dev/null || { echo scan-symbol-missing; exit 1; }
cd "$HOME/pcwork"
python3 bootreg.py "$HOME/hopay/$NAME.payload" "hopay2/${NAME}r.payload" 0x600 >/dev/null
PAYLOAD_NAME="$NAME" python3 - <<'PY'
import os,struct
d=open(os.path.expanduser('~/hopay/'+os.environ['PAYLOAD_NAME']+'.payload'),'rb').read(80)
vb,_,_,_,end,_,mem=struct.unpack_from('<7Q',d,16)
ram=end-vb-((2492203008+0x3fff)&~0x3fff)
lst=mem-0x100000
assert ram>0 and ram%0x4000==0 and lst==0x17fe00000
open('/tmp/'+os.environ['PAYLOAD_NAME']+'-offsets','w').write('%x %x\n'%(ram,lst))
print('payload-built; offsets checked', hex(ram),hex(lst))
PY
