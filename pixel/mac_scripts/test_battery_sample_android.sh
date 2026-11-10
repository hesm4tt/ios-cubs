#!/bin/bash
set -eu
export PATH="$PATH:/opt/homebrew/bin"
dir=$(adb shell 'mktemp -d /data/local/tmp/cubs-batt-test.XXXXXX' | tr -d '\r')
case "$dir" in /data/local/tmp/cubs-batt-test.*) ;; *) echo invalid-test-dir; exit 1;; esac
cleanup() { adb shell rm -rf "$dir" >/dev/null 2>&1 || echo cleanup-failed; rm -f /tmp/cubs-batt-sample.bin; }
trap cleanup EXIT
adb push /tmp/battsrv-test-once "$dir/battsrv" >/dev/null
adb shell "chmod 700 '$dir/battsrv'; touch '$dir/ring'; '$dir/battsrv' '$dir/ring'" 
adb shell "dd if='$dir/ring' of='$dir/sample' bs=1 skip=16728064 count=68 2>/dev/null"
adb pull "$dir/sample" /tmp/cubs-batt-sample.bin >/dev/null
python3 - <<'PY'
import struct
p='/tmp/cubs-batt-sample.bin'
d=open(p,'rb').read()
assert len(d)==68, len(d)
magic,seq,*v=struct.unpack('<II15i',d)
assert magic==0x31544142 and seq==2 and v[0]==60
assert 0<=v[1]<=10000 and v[6] in (0,1) and 0<=v[7]<=4
print('sample valid: percent=%d external=%d status=%d usb-type=%d' % (v[1]//100,v[6],v[7],v[12]))
PY
