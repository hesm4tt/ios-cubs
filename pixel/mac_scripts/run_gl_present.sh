#!/bin/bash
# run_gl_present.sh (Mac): supervised test of GPU presentation (plan "make iOS rendering fast", Phase 2): payload = production cubswifi with boot arg cubs_blit=0
# (XNU no longer copies into the scanout pages or replays the DPU commit); the launcher kills drmfb2 and starts glsrv.pres with GL_PRESENT=1.
# Rollback: nothing persistent is changed (the runner restores production); the old path = just the production launcher.
set -eu
export PATH="$PATH:/opt/homebrew/bin"
cd "$HOME"
P=pcwork/hopay2
if [ ! -f $P/cubspresr.payload ]; then
  cp $P/cubswifir.payload $P/cubspresr.payload
  n=$(grep -c -a 'cubs_blit=3' $P/cubspresr.payload || true)
  sed -i '' 's/cubs_blit=3/cubs_blit=0/' $P/cubspresr.payload
  strings $P/cubspresr.payload | grep -m1 'cubs_blit='
fi
cp /tmp/cubswifi-offsets /tmp/cubspres-offsets
export NAME=cubspres JB_OK=1 WDOG=${WDOG:-600} WAIT=${WAIT:-200}
export PUSH="$HOME/glsrv.new:/data/local/ios/glsrv.pres"
adb push $HOME/drmfb2.drop /data/local/ios/drmfb2.drop >/dev/null; adb shell chmod 755 /data/local/ios/drmfb2.drop
export LAUNCHER_SED='s#^RING_DEV=/dev/cubs_ram RING_BASE=0 ./glsrv #GL_PRESENT=1 RING_DEV=/dev/cubs_ram RING_BASE=0 ./glsrv.pres #; s#( ./drmfb2 \$D/fblist.bin hold#( DROP_MASTER=1 ./drmfb2.drop \$D/fblist.bin hold#'
export EVIDENCE='adb pull /data/local/ios/glsrv.log "$OUT/glsrv.log" >/dev/null; adb pull /data/local/ios/drmfb.log "$OUT/drmfb.log" >/dev/null || true'
exec bash $HOME/run_guarded.sh
