#!/bin/bash
export PATH=$PATH:/opt/homebrew/bin
adb shell "echo 'touch /data/local/ios/snd' | /data/adb/ksu/bin/ksud debug su"
export POST='/system/bin/logcat -b all -d | grep CubsSnd > /data/local/ios/snd-player-test.log; tail -20 /data/local/ios/snd-player-test.log; tail -10 /data/local/ios/sndsrv.log'
export TAILN=8
bash "$HOME/cycle.sh" snd4 '/redwood/bin/sound_test springboard route wait 2 tone 5' 'cubs_sound=1' 300 'sound_test:|ring to Android' > /tmp/snd4-cycle.out 2>&1
