"""Exercise the embedded watchdog against disposable files, never a phone."""
import pathlib
import subprocess
import tempfile

source = pathlib.Path(__file__).with_name("wifistatus3_run.sh").read_text()
start = source.index("( sleep 420\n")
end = source.index(") &''')", start)
body = source[start + len("( sleep 420\n"):end]
flags = ("boot_ios", "smp", "cam", "snd", "camid", "camdelay", "noring", "cpu6_khz")

for missing_payload in (False, True):
    with tempfile.TemporaryDirectory(prefix="cubs-watchdog-test-") as tmp:
        root = pathlib.Path(tmp)
        (root / "ho.payload").write_text("experimental")
        if not missing_payload:
            (root / "ho.payload.prod").write_text("production")
        (root / "ios_start.sh").write_text("experimental launcher")
        (root / "ios_start.pre-wifistatus").write_text("production launcher")
        for flag in flags:
            (root / flag).touch()
        script = 'D="$1"\nsync() { :; }\nreboot() { echo reboot >> "$D/events"; }\n' + body
        subprocess.run(["bash", "-c", script, "test", str(root)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        assert (root / "events").read_text() == "reboot\n"
        assert (root / "ios_start.sh").read_text() == "production launcher"
        assert not any((root / flag).exists() for flag in flags)
        if missing_payload:
            assert (root / "ho.payload").read_text() == "experimental"
            assert "payload restore failed" in (root / "watchdog.log").read_text()
        else:
            assert (root / "ho.payload").read_text() == "production"
print("disposable recovery tests passed: normal and missing payload")
