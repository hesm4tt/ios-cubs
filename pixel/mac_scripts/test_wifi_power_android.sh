#!/bin/bash
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
J=/opt/homebrew/opt/openjdk@21/bin
T=$(mktemp -d /tmp/cubs-wifi-power.XXXXXX)
cleanup() { adb shell rm -f /data/local/tmp/cubs-wifi-power-probe.dex /data/local/tmp/test_wifi_power_android.sh >/dev/null 2>&1 || :; rm -rf "$T"; }
trap cleanup EXIT
mkdir "$T/classes" "$T/dex"
"$J/javac" --release 8 -Xlint:-options -cp "$HOME/apkbuild/android-all.jar" -d "$T/classes" /tmp/WifiPowerProbe.java
"$J/java" -cp "$HOME/apkbuild/r8.jar" com.android.tools.r8.D8 --release --min-api 26 --lib "$HOME/apkbuild/android-all.jar" --output "$T/dex" "$T/classes/com/cubs/probe/WifiPowerProbe.class"
adb push "$T/dex/classes.dex" /data/local/tmp/cubs-wifi-power-probe.dex >/dev/null
adb push /tmp/cubs-wifi-power-phone.sh /data/local/tmp/test_wifi_power_android.sh >/dev/null
printf '%s\n' 'sh /data/local/tmp/test_wifi_power_android.sh' | adb shell /data/adb/ksu/bin/ksud debug su
