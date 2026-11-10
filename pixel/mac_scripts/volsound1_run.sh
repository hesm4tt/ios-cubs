#!/bin/bash
export PATH=$PATH:/opt/homebrew/bin
adb shell "echo 'touch /data/local/ios/snd' | /data/adb/ksu/bin/ksud debug su"
export SHOTGRAB=1 TAILN=30 OSLOG='com.apple.backboardd com.apple.SpringBoard'
export POST='tail -8 /data/local/ios/sndsrv.log'
bash "$HOME/cycle.sh" volsound1 '/redwood/bin/sound_test springboard route wait 2 tone 60;/redwood/bin/rwtouch wait 35 button volup wait 3 button volup wait 3 button voldown wait 3 button volup wait 3 button volup wait 3 button volup' 'cubs_sound=1 cubs_shot=1' 220 'sound_test:|redwood: audio: the volume|VolumeIncrement|VolumeDecrement|CUBS shot:' > /tmp/volsound1.out 2>&1
