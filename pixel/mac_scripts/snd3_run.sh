#!/bin/bash
export POST='logcat -d -s CubsSnd:V > /data/local/ios/snd-player-test.log; tail -20 /data/local/ios/snd-player-test.log'
export TAILN=8
bash "$HOME/cycle.sh" snd3 '/redwood/bin/sound_test springboard route wait 2 tone 5' 'cubs_sound=1' 220 'sound_test:|ring to Android' > /tmp/snd3-cycle.out 2>&1
