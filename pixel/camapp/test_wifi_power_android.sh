#!/system/bin/sh
# Separate delayed restore covers a probe crash or host disconnect.
set -u
cmd wifi status | grep -q '^Wifi is enabled$' || { echo initial-state-not-enabled; exit 1; }
( sleep 40; cmd wifi set-wifi-enabled enabled >/dev/null 2>&1 ) </dev/null >/dev/null 2>&1 &
guard=$!
cleanup() { kill "$guard" 2>/dev/null || :; cmd wifi set-wifi-enabled enabled >/dev/null 2>&1 || :; }
trap cleanup EXIT
CLASSPATH=/data/local/tmp/cubs-wifi-power-probe.dex timeout 28 /system/bin/app_process /system/bin com.cubs.probe.WifiPowerProbe
