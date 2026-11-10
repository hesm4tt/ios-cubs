#!/system/bin/sh
set -eu
ring=$(mktemp /data/local/tmp/cubs-wifi-unknown.XXXXXX)
server=
cleanup() { [ -z "$server" ] || kill "$server" 2>/dev/null || :; rm -f "$ring"; }
trap cleanup EXIT
CUBS_WIFI_RING="$ring" /data/local/tmp/cubs-wifi-status-unknown 10000 >/dev/null 2>&1 &
server=$!
sleep 1
kill -0 "$server"
v=$(dd if="$ring" bs=1 skip=$((0x2000008)) count=4 2>/dev/null | od -An -tu4 | tr -d ' \n')
[ "$v" = 2 ]
echo unavailable-status-is-unknown
