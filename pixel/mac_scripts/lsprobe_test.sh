#!/bin/bash
# LaunchServices probe run: the sideload test (clone app in the inbox) plus /redwood/bin/lsprobe, which prints what LaunchServices knows about the
# baked app, the sideloaded clone and Safari, and what openURL / SBSOpenSensitiveURLAndUnlock do. Build on the Mac, then:
#   JB_OK=1 NAME=cubslsp WAIT=230 LOOP=0 OUT=/tmp/g-lsp bash run_guarded.sh   (run_lsprobe.sh does this)
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
cd "$HOME"
# sideload_test.sh with another image name and payload name; the persist image builder with lsprobe added to the test binaries
perl -pe 's#build_persist_image.sh#build_persist_lsp_image.sh#; s#root_cubs_sideload.apfs#root_cubs_lsp.apfs#g; s#PAYLOAD_NAME=cubssl#PAYLOAD_NAME=cubslsp#; s#^/redwood/bin/battery_test open persisttest://x#/redwood/bin/rwtouch wait 125
/redwood/bin/lsprobe#' \
    sideload_test.sh > /tmp/sideload_lsp.sh
perl -pe 's#\$HOME/rwhttp"#\$HOME/rwhttp \$HOME/lsprobe"#; $_ .= "cp \"\$HOME/diag-sideload.sh\" \"\$U/jb/root/var/jb/etc/diag-sideload.sh\"\nchmod 755 \"\$U/jb/root/var/jb/etc/diag-sideload.sh\"\n" if /^chmod 755 .*cubs-persist\.sh/' build_persist_image.sh > build_persist_lsp_image.sh
grep -n -E "diag-sideload|lsprobe" build_persist_lsp_image.sh
ldid -S"$HOME/lsprobe.entitlements" "$HOME/lsprobe"
grep -n lsprobe build_persist_lsp_image.sh /tmp/sideload_lsp.sh
bash /tmp/sideload_lsp.sh
