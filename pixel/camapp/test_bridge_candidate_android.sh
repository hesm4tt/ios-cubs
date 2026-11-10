#!/system/bin/sh
set -u
probe=
cleanup() {
  am force-stop com.cubs.cam >/dev/null 2>&1 || :
  [ -z "$probe" ] || kill "$probe" 2>/dev/null || :
  rm -f /data/local/tmp/cubs-bridge-smoke.log
}
trap cleanup EXIT
/data/local/tmp/cubs-bridge-smoke > /data/local/tmp/cubs-bridge-smoke.log 2>&1 &
probe=$!
for i in 1 2 3 4 5; do grep -q listeners-ready /data/local/tmp/cubs-bridge-smoke.log && break; sleep 1; done
if ! grep -q listeners-ready /data/local/tmp/cubs-bridge-smoke.log; then cat /data/local/tmp/cubs-bridge-smoke.log; exit 1; fi
am start-foreground-service --user 0 -n com.cubs.cam/com.cubs.cam.CamService --es id 0 --ei w 640 --ei h 480 >/dev/null || exit 1
am start-foreground-service --user 0 -n com.cubs.cam/com.cubs.cam.SndService >/dev/null || exit 1
wait "$probe"; result=$?
probe=
cat /data/local/tmp/cubs-bridge-smoke.log
exit "$result"
