#!/bin/bash
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
J=/opt/homebrew/opt/openjdk@21/bin
T=$(mktemp -d /tmp/cubs-wifi-current.XXXXXX)
phone=/data/local/tmp/cubs-wifi-current-probe.dex
cleanup() { adb shell rm -f "$phone" >/dev/null 2>&1 || :; rm -rf "$T"; }
trap cleanup EXIT
mkdir "$T/classes" "$T/dex"
"$J/javac" --release 8 -Xlint:-options -cp "$HOME/apkbuild/android-all.jar" -d "$T/classes" /tmp/WifiCurrentNetworkProbe.java
"$J/java" -cp "$HOME/apkbuild/r8.jar" com.android.tools.r8.D8 --release --min-api 26 --lib "$HOME/apkbuild/android-all.jar" --output "$T/dex" "$T/classes/com/cubs/probe/WifiCurrentNetworkProbe.class"
adb push "$T/dex/classes.dex" "$phone" >/dev/null
printf '%s\n' "CLASSPATH=$phone timeout 10 /system/bin/app_process /system/bin com.cubs.probe.WifiCurrentNetworkProbe" | adb shell /data/adb/ksu/bin/ksud debug su
