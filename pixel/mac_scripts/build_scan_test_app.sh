#!/bin/bash
set -euo pipefail
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export PATH="$JAVA_HOME/bin:$PATH"
build=$(mktemp -d /tmp/cubs-scan-build.XXXXXX)
cd "$build"
for f in android-all.jar r8.jar aapt2 framework-res.apk debug.keystore CamActivity.java CamService.java SndService.java; do
  ln -s "$HOME/apkbuild/$f" "$f"
done
cp /tmp/WifiStatusService.java /tmp/WifiScanCollector.java /tmp/WifiScanSnapshot.java .
sed 's/package="com.cubs.cam"/package="com.cubs.scantest"/' /tmp/AndroidManifest.xml > AndroidManifest.xml
mkdir cls
javac --release 8 -cp android-all.jar -d cls CamActivity.java CamService.java SndService.java WifiStatusService.java WifiScanCollector.java WifiScanSnapshot.java
java -cp r8.jar com.android.tools.r8.D8 --release --min-api 26 --lib android-all.jar --output . $(find cls -name '*.class')
./aapt2 link -o out.apk -I framework-res.apk --manifest AndroidManifest.xml --min-sdk-version 26 --target-sdk-version 29
cp out.apk app.apk
zip -q -j app.apk classes.dex
jarsigner -keystore debug.keystore -storepass android -keypass android -sigalg SHA256withRSA -digestalg SHA-256 app.apk k >/dev/null
echo "$build/app.apk" > /tmp/cubs-scan-test-apk-path
echo test-apk-built
