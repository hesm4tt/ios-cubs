#!/bin/bash
export PATH=$PATH:/opt/homebrew/bin
adb shell "echo 'sh /data/local/tmp/wifi_android_test.sh' | /data/adb/ksu/bin/ksud debug su"
