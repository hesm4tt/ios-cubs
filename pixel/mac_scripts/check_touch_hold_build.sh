#!/bin/bash
set -u
U="$HOME/unixnu-pixel11/hackios-upstream"
S="$U/xnu-src/xnu-8796.121.2/osfmk/arm64/loader_return.c"
T=$(mktemp -d /tmp/cubs-touch-build.XXXXXX) || exit 1
cp -p "$S" "$T/loader.c" || exit 1
cp -p "$HOME/cubs_touch.c.inc" "$T/touch.inc" || exit 1
cleanup() {
  cp -p "$T/loader.c" "$S"
  cp -p "$T/touch.inc" "$HOME/cubs_touch.c.inc"
  touch "$S"
  (cd "$U" && bash xnu-build.sh > /tmp/cubs-touch-restored-build.log 2>&1) || :
  cmp -s "$S" "$T/loader.c" && cmp -s "$HOME/cubs_touch.c.inc" "$T/touch.inc" && echo sources-restored
}
trap cleanup EXIT
cp /tmp/cubs_touch.proposed.inc "$HOME/cubs_touch.c.inc" || exit 1
ROOT="$HOME/hopay/root_prodposter.apfs" bash "$HOME/mac_build.sh" cubstouch-check.payload \
  'debug=0x8 keepsyms=1 cpus=1 rd=md0 loader_return_after=100000 cubs_blit=3 cubs_touch=1 cubs_touch_div=16 gl=1 cubs_net=1' > /tmp/cubs-touch-payload-build.log 2>&1 || exit 1
if grep -qE '(^|[[:space:]])(fatal )?error:' "$HOME/xnu_build_blit.log"; then
  grep -E '(^|[[:space:]])(fatal )?error:' "$HOME/xnu_build_blit.log" | head -5
  exit 1
fi
grep -E 'LD mach.development|built kernel at|symbolset.*Error' "$HOME/xnu_build_blit.log" | tail -4 || :
echo experimental-payload-built
