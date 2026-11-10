#!/bin/bash
# The production system image (run on the Mac): the Procursus/Sileo prefix with cubs-persist.sh, brightbridge (/var/jb/usr/bin) and libwkfix
# (/var/jb/usr/lib, added to kern.exec_inject by cubs-persist.sh) -> ~/hopay/system-jb.apfs. No test apps: the userland apps dir must hold only
# MetalDemo.app (wk_test.sh puts WKProbe there for its build and removes it again). Install with inst_bright.sh-style steps (see inst_wkfix.sh).
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
cd "$HOME"
source "$HOME/unixnu-pixel11/hackios-upstream/xnu-env.sh"
export THEOS="$HOME/unixnu-pixel11/theos"
U="$HOME/unixnu-pixel11/hackios-upstream"
[ "$(ls "$U/apps")" = "MetalDemo.app" ] || { echo "unexpected apps dir: $(ls "$U/apps")"; exit 1; }
xnu-clang -arch arm64 -isysroot "$THEOS/sdks/iPhoneOS16.5.sdk" -O1 -o brightbridge brightbridge.c
ldid -Sbrightbridge.entitlements brightbridge
xnu-clang -arch arm64 -isysroot "$THEOS/sdks/iPhoneOS16.5.sdk" -fno-objc-arc -O1 -dynamiclib -framework Foundation -framework CoreGraphics -lobjc -o libwkfix.dylib libwkfix.m
perl -pe '$_ .= "mkdir -p \"\$U/jb/root/var/jb/usr/bin\" \"\$U/jb/root/var/jb/usr/lib\"\ncp \"\$HOME/brightbridge\" \"\$U/jb/root/var/jb/usr/bin/brightbridge\"\ncp \"\$HOME/libwkfix.dylib\" \"\$U/jb/root/var/jb/usr/lib/libwkfix.dylib\"\nchmod 755 \"\$U/jb/root/var/jb/usr/bin/brightbridge\" \"\$U/jb/root/var/jb/usr/lib/libwkfix.dylib\"\n" if /^chmod 755 .*cubs-persist\.sh/' build_persist_image.sh > build_persist_prod_image.sh
grep -n -E "brightbridge|libwkfix" build_persist_prod_image.sh
export IMAGE_OUTPUT="$HOME/hopay/root_cubs_prodsys.apfs"
bash build_persist_prod_image.sh
ls -la "$HOME/hopay/system-jb.apfs"
echo BUILD-OK
