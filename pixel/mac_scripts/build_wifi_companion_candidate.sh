#!/bin/bash
set -euo pipefail
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export PATH="$JAVA_HOME/bin:$PATH"
T=$(mktemp -d /tmp/cubs-wifi-companion.XXXXXX)
cleanup() { rm -rf "$T"; }
trap cleanup EXIT
for f in android-all.jar r8.jar aapt2 framework-res.apk debug.keystore; do ln -s "$HOME/apkbuild/$f" "$T/$f"; done
cp /tmp/cubs-wifi-app/AndroidManifest.xml /tmp/cubs-wifi-app/*.java "$T/"
cd "$T"
mkdir cls
javac --release 8 -Xlint:-options -cp android-all.jar -d cls CamActivity.java CamService.java SndService.java WifiStatusService.java WifiScanCollector.java WifiScanSnapshot.java
java -cp r8.jar com.android.tools.r8.D8 --release --min-api 26 --lib android-all.jar --output . $(find cls -name '*.class')
./aapt2 link -o out.apk -I framework-res.apk --manifest AndroidManifest.xml --min-sdk-version 26 --target-sdk-version 29
cp out.apk candidate.apk
zip -q -j candidate.apk classes.dex
jarsigner -keystore debug.keystore -storepass android -keypass android -sigalg SHA256withRSA -digestalg SHA-256 candidate.apk k >/dev/null
jarsigner -verify candidate.apk >/dev/null
cp candidate.apk /tmp/cubs-wifi-companion-candidate.apk
echo companion-candidate-built
