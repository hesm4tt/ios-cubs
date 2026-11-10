#!/bin/bash
set -euo pipefail
U="$HOME/unixnu-pixel11/hackios-upstream"
S="$U/xnu-src/xnu-8796.121.2/iokit/Kernel/RedwoodBattery.cpp"
B=$(mktemp -d /tmp/cubs-batt-build.XXXXXX)
cp -p "$S" "$B/original"
cp -p "$HOME/pcwork/hopay2/cubsscan1r.payload" "$B/scan.payload"
cp -p /tmp/cubsscan1-offsets "$B/scan.offsets"
cleanup() {
  cp -p "$B/original" "$S"
  touch "$S"
  (cd "$U" && bash xnu-build.sh > /tmp/cubs-battery-final-restore.log 2>&1) || :
  cmp -s "$B/original" "$S" || echo battery-source-restore-failed
  cp -p "$B/scan.payload" "$HOME/pcwork/hopay2/cubsscan1r.payload"
  cp -p "$B/scan.offsets" /tmp/cubsscan1-offsets
}
trap cleanup EXIT
cp /tmp/RedwoodBattery.proposed.cpp "$S"
touch "$S"
ROOT_IMAGE="${ROOT_IMAGE:-$HOME/hopay/root_cubsscan_late.apfs}" bash /tmp/build_cubs_scan_payload.sh
cp "$HOME/pcwork/hopay2/cubsscan1r.payload" "$HOME/pcwork/hopay2/cubsbatt-test.payload"
cp /tmp/cubsscan1-offsets /tmp/cubsbatt-test-offsets
echo battery-test-payload-built
