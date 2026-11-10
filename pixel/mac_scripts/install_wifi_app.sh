#!/bin/bash
set -euo pipefail
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export PATH=$JAVA_HOME/bin:/opt/homebrew/bin:$PATH
old=$(adb shell pm path com.cubs.cam | tr -d "\r" | sed -n 's/^package://p' | head -1)
[ -n "$old" ]
adb pull "$old" /tmp/cubsapp.pre-wifi.apk >/dev/null
oldcert=$(keytool -printcert -jarfile /tmp/cubsapp.pre-wifi.apk | grep SHA256 | head -1)
newcert=$(keytool -printcert -jarfile "$HOME/apkbuild/app.apk" | grep SHA256 | head -1)
[ -n "$oldcert" ] && [ "$oldcert" = "$newcert" ]
echo signing-key-matches
adb install -r -g "$HOME/apkbuild/app.apk"
