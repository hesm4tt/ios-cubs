#!/bin/bash
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
J=/opt/homebrew/opt/openjdk@21/bin
T=$(mktemp -d /tmp/cubs-wifi-saved.XXXXXX)
phone=/data/local/tmp/cubs-wifi-saved-probe.dex
cleanup() { adb shell rm -f "$phone" >/dev/null 2>&1 || :; rm -rf "$T"; }
trap cleanup EXIT
mkdir "$T/classes" "$T/dex"
"$J/javac" --release 8 -Xlint:-options -cp "$HOME/apkbuild/android-all.jar" -d "$T/classes" /tmp/WifiSavedConnectProbe.java
"$J/java" -cp "$HOME/apkbuild/r8.jar" com.android.tools.r8.D8 --release --min-api 26 --lib "$HOME/apkbuild/android-all.jar" --output "$T/dex" "$T/classes/com/cubs/probe/WifiSavedConnectProbe.class" "$T/classes/com/cubs/probe/WifiSavedConnectProbe\$1.class"
if [ "${BUILD_ONLY:-0}" = 1 ]; then
  cp "$T/dex/classes.dex" /tmp/cubs-wifi-saved-probe.dex
  echo saved-probe-built
  exit 0
fi
adb push "$T/dex/classes.dex" "$phone" >/dev/null
printf '%s\n' "CLASSPATH=$phone timeout 15 /system/bin/app_process /system/bin com.cubs.probe.WifiSavedConnectProbe" | adb shell /data/adb/ksu/bin/ksud debug su
