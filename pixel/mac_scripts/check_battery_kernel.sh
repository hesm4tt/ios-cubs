#!/bin/bash
set -u
U="$HOME/unixnu-pixel11/hackios-upstream"
S="$U/xnu-src/xnu-8796.121.2/iokit/Kernel/RedwoodBattery.cpp"
K="$U/xnu-src/xnu-8796.121.2/BUILD/obj/DEVELOPMENT_ARM64_BCM2837/mach.development.bcm2837"
B=$(mktemp -d /tmp/cubs-battery-check.XXXXXX) || exit 1
cp -p "$S" "$B/original" || exit 1
cleanup() {
  cp -p "$B/original" "$S"
  touch "$S"
  (cd "$U" && bash xnu-build.sh > /tmp/cubs-battery-restored-build.log 2>&1) || :
  cmp -s "$B/original" "$S" || echo source-restore-failed
  echo restored-source-checked
}
trap cleanup EXIT
cp /tmp/RedwoodBattery.proposed.cpp "$S" || exit 1
touch "$S"
cd "$U" || exit 1
bash xnu-build.sh > /tmp/cubs-battery-kernel-build.log 2>&1
rc=$?
echo "build-exit=$rc"
grep -E 'RedwoodBattery.cpp:.*(error:|warning:)|RedwoodBattery.o|BUILD (SUCCEEDED|FAILED)' /tmp/cubs-battery-kernel-build.log | tail -12 || :
[ -s "$K" ] && echo linked-kernel-present
