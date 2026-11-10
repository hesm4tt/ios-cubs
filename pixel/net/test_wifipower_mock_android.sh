#!/system/bin/sh
set -eu
ring=$(mktemp /data/local/tmp/cubs-power-mock.XXXXXX)
marker="$ring.marker"; server=
cleanup() { [ -z "$server" ] || kill "$server" 2>/dev/null || :; rm -f "$ring" "$marker"; }
trap cleanup EXIT
CUBS_POWER_RING="$ring" CUBS_POWER_TEST_HELPER=/data/local/tmp/wifipower_mock CUBS_POWER_MOCK_MARKER="$marker" /data/local/tmp/wifipowersrv_test &
server=$!
sleep 1
kill -0 "$server"
readword() { dd if="$ring" bs=1 skip="$1" count=4 2>/dev/null | od -An -tu4 | tr -d ' \n'; }
writeword() { printf "$1" | dd of="$ring" bs=1 seek="$2" conv=notrunc 2>/dev/null; }
waitword() { n=0; while [ "$(readword "$1")" != "$2" ]; do n=$((n+1)); [ "$n" -lt 50 ] || return 1; sleep 0.1; done; }
# Request off, cancel before claim: no helper invocation.
writeword '\000\000\000\000' $((0x2300104))
writeword '\003\000\000\000' $((0x2300180))
writeword '\002\000\000\000' $((0x2300100))
waitword $((0x2300080)) 2
[ "$(readword $((0x2300084)))" = 2 ] && [ ! -e "$marker" ]
echo power-cancel-ok
# Request on and commit only after claim.
writeword '\001\000\000\000' $((0x2300104))
writeword '\000\000\000\000' $((0x2300180))
writeword '\004\000\000\000' $((0x2300100))
waitword $((0x23000c0)) 4
writeword '\004\000\000\000' $((0x2300180))
waitword $((0x2300080)) 4
[ "$(readword $((0x2300084)))" = 1 ] && [ "$(cat "$marker")" = on ]
echo power-commit-ok
