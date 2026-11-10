#!/bin/bash
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
adb shell 'cmd wifi status | grep -q "^Wifi is enabled$"' || { echo initial-state-not-enabled; exit 1; }
J=/opt/homebrew/opt/openjdk@21/bin
T=$(mktemp -d /tmp/cubs-wifi-power-helper.XXXXXX)
phone=/data/local/tmp/cubs-wifi-power-helper.dex
cleanup() { adb shell rm -f "$phone" >/dev/null 2>&1 || :; rm -rf "$T"; }
trap cleanup EXIT
mkdir "$T/classes" "$T/dex"
"$J/javac" --release 8 -Xlint:-options -cp "$HOME/apkbuild/android-all.jar" -d "$T/classes" /tmp/PrivilegedWifiPower.java
"$J/java" -cp "$HOME/apkbuild/r8.jar" com.android.tools.r8.D8 --release --min-api 26 --lib "$HOME/apkbuild/android-all.jar" --output "$T/dex" "$T/classes/com/cubs/cam/PrivilegedWifiPower.class"
adb push "$T/dex/classes.dex" "$phone" >/dev/null
printf '%s\n' "CLASSPATH=$phone timeout 12 /system/bin/app_process /system/bin com.cubs.cam.PrivilegedWifiPower invalid" | adb shell /data/adb/ksu/bin/ksud debug su
printf '%s\n' "CLASSPATH=$phone timeout 12 /system/bin/app_process /system/bin com.cubs.cam.PrivilegedWifiPower on" | adb shell /data/adb/ksu/bin/ksud debug su
