#!/bin/bash
set -u
D="$HOME/unixnu-pixel11/hackios-upstream/xnu-src/xnu-8796.121.2/bsd/dev"
S="$HOME/unixnu-pixel11/hackios-upstream/xnu-src/xnu-8796.121.2/bsd/sys"
B=$(mktemp -d /tmp/cubs-scan-kernel-check.XXXXXX) || exit 1
[ ! -e "$D/redwood_scan_decode.h" ] || { echo header-already-exists; exit 1; }
[ ! -e "$D/redwood_join_security.h" ] || { echo join-header-already-exists; exit 1; }
cp -p "$D/redwood_cubs_net.c" "$B/original.c" || exit 1
cp -p "$S/redwood_sta.h" "$B/original-sta.h" || exit 1
cleanup() {
  cp -p "$B/original.c" "$D/redwood_cubs_net.c"
  cp -p "$B/original-sta.h" "$S/redwood_sta.h"
  # The just-built object contains experimental code; force an incremental
  # build to recompile the restored source rather than silently reusing it.
  touch "$D/redwood_cubs_net.c" "$S/redwood_sta.h"
  rm -f "$D/redwood_scan_decode.h"
  rm -f "$D/redwood_join_security.h"
  # Restore the linked kernel as well: the project's build wrapper may use a
  # linked artifact even when a later symbol-set step returns an error.
  ( cd "$HOME/unixnu-pixel11/hackios-upstream" && bash xnu-build.sh > /tmp/cubs-restored-kernel-build.log 2>&1 ) || :
  K="$HOME/unixnu-pixel11/hackios-upstream/xnu-src/xnu-8796.121.2/BUILD/obj/DEVELOPMENT_ARM64_BCM2837/mach.development.bcm2837"
  if /opt/homebrew/opt/llvm/bin/llvm-nm "$K" 2>/dev/null | grep -q _cw_scan_data; then
    echo 'WARNING: experimental symbol remains in linked kernel' >&2
  fi
}
trap cleanup EXIT
cp /tmp/redwood_cubs_net.c "$D/redwood_cubs_net.c" || exit 1
cp /tmp/redwood_sta.h "$S/redwood_sta.h" || exit 1
cp /tmp/redwood_scan_decode.h "$D/redwood_scan_decode.h" || exit 1
cp /tmp/redwood_join_security.h "$D/redwood_join_security.h" || exit 1
cd "$HOME/unixnu-pixel11/hackios-upstream" || exit 1
if bash xnu-build.sh > /tmp/cubs-scan-kernel-build.log 2>&1; then
  echo kernel-build-command-ok
else
  echo kernel-build-command-failed
fi
grep -E '(^|[[:space:]])error:' /tmp/cubs-scan-kernel-build.log | head -8 || :
grep -E 'CC redwood_cubs_net.o|BUILD SUCCEEDED|BUILD FAILED' /tmp/cubs-scan-kernel-build.log | tail -5 || :
