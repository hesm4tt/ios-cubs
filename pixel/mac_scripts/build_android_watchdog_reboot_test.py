"""Build an Android reboot test using only disposable recovery files."""
from pathlib import Path

src = Path(__file__).with_name("wifistatus3_run.sh").read_text()
start = src.index("( sleep 420\n") + len("( sleep 420\n")
end = src.index(") &''')", start)
body = src[start:end]
test = '''#!/system/bin/sh
set -u
D=/data/local/tmp/cubs_watchdog_reboot_test
[ ! -e "$D" ] || exit 1
mkdir "$D" || exit 1
reboot() { echo requested > "$D/reboot-requested"; sync; /system/bin/reboot; }
echo experimental > "$D/ho.payload"
echo production > "$D/ho.payload.prod"
echo test-launcher > "$D/ios_start.sh"
echo production-launcher > "$D/ios_start.pre-wifistatus"
touch "$D/boot_ios" "$D/smp" "$D/cam" "$D/snd" "$D/camid" "$D/camdelay" "$D/noring" "$D/cpu6_khz"
sleep 5
''' + body
Path("/tmp/cubs_watchdog_reboot_test.sh").write_text(test)
