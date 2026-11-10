#!/bin/bash
# Brightness bridge test image (run on the Mac): persistsrv with the /brightness/<thousandths> handler (NDK), brightbridge for iOS (signed with
# brightbridge.entitlements), a root image whose job list runs `brightbridge sweep &`, and the payload cubsbr. Then run_bright.sh.
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
cd "$HOME"
T=/opt/homebrew/share/android-ndk/toolchains/llvm/prebuilt/darwin-x86_64
$T/bin/aarch64-linux-android31-clang -O2 -Wall -o persistsrv.new persistsrv.c
source "$HOME/unixnu-pixel11/hackios-upstream/xnu-env.sh"
export THEOS="$HOME/unixnu-pixel11/theos"
xnu-clang -arch arm64 -isysroot "$THEOS/sdks/iPhoneOS16.5.sdk" -O1 -o brightbridge brightbridge.c
ldid -Sbrightbridge.entitlements brightbridge
ldid -e brightbridge | head -4
perl -pe 's#\$HOME/rwhttp"#\$HOME/rwhttp \$HOME/brightbridge"#' build_persist_image.sh > build_persist_bright_image.sh
grep -n brightbridge build_persist_bright_image.sh
export JOBS_TAIL='/redwood/bin/brightbridge sweep &
/redwood/bin/rwtouch wait 150'
export IMAGE_OUTPUT="$HOME/hopay/root_cubs_bright.apfs"
bash build_persist_bright_image.sh
unset JOBS_TAIL
PAYLOAD_NAME=cubsbr ROOT_IMAGE="$HOME/hopay/root_cubs_bright.apfs" BOOT_EXTRA="cubs_shot=1 cubs_sound=1 cubs_hb=1" bash build_big_payload.sh
echo BUILD-OK
