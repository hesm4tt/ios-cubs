#!/bin/bash
# inst_jb.sh: install the production payload with the Sileo/Procursus prefix and persistence (cubsprodjb), run on the Mac with the phone in Android.
# What changes on the phone (/data/local/ios): ho.payload + ho.payload.prod (backup ho.payload.pre-jb), env.sh (RAMOFF follows the new payload; backup
# env.sh.pre-jb), ios_start.sh (backup ios_start.pre-jb: the flag `jb` selects system-jb.img and starts persistsrv), system-jb.img, persistsrv, flag `jb`.
# Rollback on the phone:  cd /data/local/ios; cp ho.payload.pre-jb ho.payload.prod; cp ho.payload.pre-jb ho.payload; cp env.sh.pre-jb env.sh; cp ios_start.pre-jb ios_start.sh; rm -f jb
# (or just `rm jb` to boot the plain iOS image with the new payload).
set -eu
export PATH="$PATH:/opt/homebrew/bin"
NAME=${NAME:-cubsprodjb}
read -r RAMOFF LISTOFF < "/tmp/$NAME-offsets"
[ "$LISTOFF" = 17fe00000 ] || { echo "unexpected LISTOFF $LISTOFF"; exit 1; }
[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ] || { echo android-not-ready; exit 1; }
rootsh() { printf '%s\n' "$1" | adb shell /data/adb/ksu/bin/ksud debug su; }
rootsh 'D=/data/local/ios; cmp $D/ho.payload $D/ho.payload.prod || exit 1; for f in boot_ios smp cam camid camdelay noring cpu6_khz jb ho.payload.pre-jb ios_start.pre-jb env.sh.pre-jb; do test ! -e $D/$f || { echo leftover $f; exit 1; }; done; echo preflight-ok' | grep preflight-ok >/dev/null
adb push "$HOME/pcwork/hopay2/${NAME}r.payload" /data/local/tmp/prodjb.payload >/dev/null
adb push "$HOME/hopay/system-jb.apfs" /data/local/tmp/system-jb.img >/dev/null
adb push "$HOME/persistsrv" /data/local/tmp/persistsrv.new >/dev/null
adb pull /data/local/ios/ios_start.sh /tmp/prodjb-launcher.sh >/dev/null
python3 - <<'PY'
p = '/tmp/prodjb-launcher.sh'
s = open(p).read()
a = 'cat $D/system.img > /dev/cubs_ram'
b = '[ -x $D/netsrv ] && sh $D/netsrv.sh &'
assert s.count(a) == 1 and s.count(b) == 1 and 'system-jb.img' not in s
s = s.replace(a, 'if [ -f $D/jb ] && [ -f $D/system-jb.img ]; then cat $D/system-jb.img > /dev/cubs_ram; else cat $D/system.img > /dev/cubs_ram; fi')
s = s.replace(b, b + '\n[ -f $D/jb ] && [ -x $D/persistsrv ] && ( $D/persistsrv > $D/persistsrv.log 2>&1 & )')
open(p, 'w', newline='\n').write(s)
PY
adb push /tmp/prodjb-launcher.sh /data/local/tmp/prodjb-launcher.sh >/dev/null
rootsh "D=/data/local/ios; set -e; cp \$D/ho.payload.prod \$D/ho.payload.pre-jb; cp \$D/env.sh \$D/env.sh.pre-jb; cp \$D/ios_start.sh \$D/ios_start.pre-jb; cp /data/local/tmp/system-jb.img \$D/system-jb.img.new; mv -f \$D/system-jb.img.new \$D/system-jb.img; cp /data/local/tmp/persistsrv.new \$D/persistsrv; chmod 755 \$D/persistsrv; mkdir -p \$D/inbox; cp /data/local/tmp/prodjb.payload \$D/ho.payload.new-jb; cp \$D/ho.payload.new-jb \$D/ho.payload.prod.new-jb; mv -f \$D/ho.payload.prod.new-jb \$D/ho.payload.prod; mv -f \$D/ho.payload.new-jb \$D/ho.payload; printf 'export RAMOFF=$RAMOFF\nexport LISTOFF=$LISTOFF\n' > \$D/env.sh.new; mv -f \$D/env.sh.new \$D/env.sh; cp /data/local/tmp/prodjb-launcher.sh \$D/ios_start.new; chmod 755 \$D/ios_start.new; mv -f \$D/ios_start.new \$D/ios_start.sh; touch \$D/jb; rm -f /data/local/tmp/prodjb.payload /data/local/tmp/system-jb.img /data/local/tmp/persistsrv.new /data/local/tmp/prodjb-launcher.sh; sync; cmp \$D/ho.payload \$D/ho.payload.prod && cat \$D/env.sh && echo jb-production-installed"
