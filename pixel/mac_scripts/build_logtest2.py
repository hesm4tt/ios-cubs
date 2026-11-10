"""Create a supervised, instrumented version of the previously disabled test."""
from pathlib import Path

s = Path(__file__).with_name('log_reader_live_test.sh').read_text()
s = s.replace("# Disabled: the timing and recovery checks failed during the first live run.\necho 'disabled: live watchdog and recovery checks failed' >&2\nexit 1\n", '')
s = s.replace('pre-logtest', 'pre-logtest2').replace('logtest-launcher', 'logtest2-launcher').replace('logtest.bin', 'logtest2.bin')
s = s.replace('( sleep 210\n  echo "log reader test watchdog" >> $D/ios_start.log', '''( echo "$(date): timer started" >> $D/logtest2-watchdog.log
  sleep 210
  echo "$(date): watchdog fired" >> $D/logtest2-watchdog.log''')
s = s.replace('  rm -f $D/boot_ios $D/smp\n  sync\n  reboot', '  echo "$(date): restore attempted" >> $D/logtest2-watchdog.log\n  rm -f $D/boot_ios $D/smp\n  echo "$(date): reboot requested" >> $D/logtest2-watchdog.log\n  sync\n  reboot')
s = s.replace("rootsh 'cp /data/local/ios/ios_start.sh /data/local/ios/ios_start.pre-logtest2", "rootsh 'rm -f /data/local/ios/logtest2-watchdog.log; cp /data/local/ios/ios_start.sh /data/local/ios/ios_start.pre-logtest2")
a = s.index('sleep 100\n')
b = s.index("echo 'reading XNU", a)
s = s[:a] + '''ready=0
for i in $(seq 1 120); do
  if adb shell "grep -q 'timer started' /data/local/ios/logtest2-watchdog.log && grep -q 'XNU started' /data/local/ios/ios_start.log" 2>/dev/null; then ready=1; break; fi
  sleep 2
done
if [ "$ready" != 1 ]; then echo 'XNU startup not observed'; else sleep 20; fi
''' + s[b:]
a = s.index("echo 'waiting for phone watchdog'")
b = s.index("rootsh 'rm -f /data/local/ios/ios_start.pre-logtest2", a)
s = s[:a] + '''echo 'waiting for phone watchdog'
recovered=0
for i in $(seq 1 100); do
  if adb shell "test -f /data/local/ios/logtest2-watchdog.log && grep -q 'reboot requested' /data/local/ios/logtest2-watchdog.log && test \\\"\\$(getprop sys.boot_completed)\\\" = 1 && ! pidof drmfb2 >/dev/null && cmp /data/local/ios/ios_start.sh /data/local/ios/ios_start.pre-logtest2" 2>/dev/null; then recovered=1; break; fi
  sleep 3
done
if [ "$recovered" != 1 ]; then
  echo 'watchdog did not complete; requesting host recovery'
  rootsh 'cp /data/local/ios/ios_start.pre-logtest2 /data/local/ios/ios_start.recover.tmp && chmod 755 /data/local/ios/ios_start.recover.tmp && mv -f /data/local/ios/ios_start.recover.tmp /data/local/ios/ios_start.sh; rm -f /data/local/ios/boot_ios /data/local/ios/smp; sync; reboot' || :
  perl -e 'alarm 180; exec @ARGV' adb wait-for-device || fail reconnect
  for i in $(seq 1 60); do [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\\r")" = 1 ] && break; sleep 3; done
fi
rootsh 'cmp /data/local/ios/ho.payload /data/local/ios/ho.payload.prod && cmp /data/local/ios/ios_start.sh /data/local/ios/ios_start.pre-logtest2 && test ! -e /data/local/ios/boot_ios && test ! -e /data/local/ios/smp && ! pidof drmfb2 >/dev/null && echo recovered-ok' | grep recovered-ok || fail recovery-check
adb shell cat /data/local/ios/logtest2-watchdog.log 2>/dev/null || :
''' + s[b:]
Path('/tmp/logtest2.sh').write_text(s)
