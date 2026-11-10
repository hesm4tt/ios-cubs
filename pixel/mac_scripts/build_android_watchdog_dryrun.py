"""Generate an Android dry run of the real watchdog body; never reboot."""
from pathlib import Path

src = Path(__file__).with_name("wifistatus3_run.sh").read_text()
start = src.index("( sleep 420\n") + len("( sleep 420\n")
end = src.index(") &''')", start)
body = src[start:end]
script = '''#!/system/bin/sh
set -u
D=$(mktemp -d /data/local/tmp/cubs-watchdog-test.XXXXXX) || exit 1
cleanup() {
  rm -f "$D/ho.payload" "$D/ho.payload.prod" "$D/ho.payload.watchdog.tmp" "$D/ios_start.sh" "$D/ios_start.pre-wifistatus" "$D/ios_start.watchdog.tmp" "$D/ios_start.log" "$D/events" "$D/boot_ios" "$D/smp" "$D/cam" "$D/snd" "$D/camid" "$D/camdelay" "$D/noring" "$D/cpu6_khz"
  rm -f "$D/watchdog.log"
  rmdir "$D"
}
trap cleanup EXIT
sync() { :; }
reboot() { echo reboot >> "$D/events"; }
echo experimental > "$D/ho.payload"
echo production > "$D/ho.payload.prod"
echo test-launcher > "$D/ios_start.sh"
echo production-launcher > "$D/ios_start.pre-wifistatus"
touch "$D/boot_ios" "$D/smp" "$D/cam" "$D/snd" "$D/camid" "$D/camdelay" "$D/noring" "$D/cpu6_khz"
''' + body + '''
[ "$(cat "$D/ho.payload")" = production ] || exit 1
[ "$(cat "$D/ios_start.sh")" = production-launcher ] || exit 1
[ "$(cat "$D/events")" = reboot ] || exit 1
for flag in boot_ios smp cam snd camid camdelay noring cpu6_khz; do
  [ ! -e "$D/$flag" ] || exit 1
done
echo android-disposable-recovery-ok
'''
Path("/tmp/cubs_watchdog_dryrun.sh").write_text(script)
