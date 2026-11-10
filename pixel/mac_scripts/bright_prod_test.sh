#!/bin/bash
# Brightness bridge as the system image will carry it (run on the Mac): brightbridge (signed) goes into the jb prefix at /var/jb/usr/bin and
# cubs-persist.sh run starts it; the rebuilt system image is ~/hopay/system-jb.apfs. The test payload cubsbp is a plain jb payload on a normal root.
# Then run_bright_prod.sh pushes the system image as system-jbtest.img for one supervised boot.
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
cd "$HOME"
source "$HOME/unixnu-pixel11/hackios-upstream/xnu-env.sh"
export THEOS="$HOME/unixnu-pixel11/theos"
xnu-clang -arch arm64 -isysroot "$THEOS/sdks/iPhoneOS16.5.sdk" -O1 -o brightbridge brightbridge.c
ldid -Sbrightbridge.entitlements brightbridge
perl -pe '$_ .= "mkdir -p \"\$U/jb/root/var/jb/usr/bin\"\ncp \"\$HOME/brightbridge\" \"\$U/jb/root/var/jb/usr/bin/brightbridge\"\nchmod 755 \"\$U/jb/root/var/jb/usr/bin/brightbridge\"\n" if /^chmod 755 .*cubs-persist\.sh/' build_persist_image.sh > build_persist_bp_image.sh
grep -n brightbridge build_persist_bp_image.sh
export IMAGE_OUTPUT="$HOME/hopay/root_cubs_bp.apfs"
bash build_persist_bp_image.sh
PAYLOAD_NAME=cubsbp ROOT_IMAGE="$HOME/hopay/root_cubs_bp.apfs" BOOT_EXTRA="cubs_shot=1 cubs_sound=1 cubs_hb=1" bash build_big_payload.sh
echo BUILD-OK
