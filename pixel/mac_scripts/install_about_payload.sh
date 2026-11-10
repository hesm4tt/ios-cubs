#!/bin/bash
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
read -r ram list < /tmp/cubsaboutprod-offsets
[ "$ram" = 28b4000 ] && [ "$list" = 17fe00000 ] || { echo offsets-mismatch; exit 1; }
[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ] || { echo android-not-ready; exit 1; }
adb push "$HOME/pcwork/hopay2/cubsaboutprodr.payload" /data/local/tmp/cubsaboutprod.payload >/dev/null
printf '%s\n' 'set -e
D=/data/local/ios
cmp -s "$D/ho.payload" "$D/ho.payload.prod" || exit 1
test ! -e "$D/ho.payload.pre-about" || exit 1
for f in boot_ios smp cam snd camid camdelay noring cpu6_khz; do test ! -e "$D/$f" || exit 1; done
grep -qx "export RAMOFF=28b4000" "$D/env.sh" || exit 1
grep -qx "export LISTOFF=17fe00000" "$D/env.sh" || exit 1
cp "$D/ho.payload.prod" "$D/ho.payload.pre-about" || exit 1
cp /data/local/tmp/cubsaboutprod.payload "$D/ho.payload.new-about" || exit 1
cmp -s /data/local/tmp/cubsaboutprod.payload "$D/ho.payload.new-about" || exit 1
cp "$D/ho.payload.new-about" "$D/ho.payload.prod.new-about" || exit 1
cmp -s "$D/ho.payload.new-about" "$D/ho.payload.prod.new-about" || exit 1
mv -f "$D/ho.payload.prod.new-about" "$D/ho.payload.prod" || exit 1
mv -f "$D/ho.payload.new-about" "$D/ho.payload" || exit 1
sync
cmp -s "$D/ho.payload" "$D/ho.payload.prod" || exit 1
cmp -s "$D/ho.payload" /data/local/tmp/cubsaboutprod.payload || exit 1
rm -f /data/local/tmp/cubsaboutprod.payload
echo about-production-payload-installed' | adb shell /data/adb/ksu/bin/ksud debug su
