#!/bin/bash
# usage: bisect_wake.sh <base.img> <lo_ok> <hi_bad> ; base image must contain boot-arg cubs_deadline=30 used as the wake message limit
BASE=$1; lo=$2; hi=$3
while [ $((hi-lo)) -gt 1 ]; do
  n=$(((lo+hi)/2))
  python tools/patch_bootarg.py $BASE cubs-images/win/bis_$n.img cubs_deadline=30 cubs_deadline=$n >/dev/null 2>&1 || { echo "patch failed for $n"; exit 1; }
  bash tools/run_img_win.sh cubs-images/win/bis_$n.img bis$n 1200 > /tmp/bis_$n.out 2>&1
  if grep -q "CPM Panic\|CPM Crashed" /tmp/bis_$n.out; then res=CRASH; hi=$n; else
     python - <<PY > /tmp/bis_res.txt
d=open('cubs-images/run-bis$n/ufslog.bin','rb').read()
print('wake-replay-done' in d.decode('latin1'))
PY
     if grep -q True /tmp/bis_res.txt; then res=OK; lo=$n; else res=UNKNOWN; lo=$n; fi
  fi
  echo "N=$n $res (lo=$lo hi=$hi)"
done
echo "BISECT DONE: last good limit=$lo, first bad limit=$hi"
