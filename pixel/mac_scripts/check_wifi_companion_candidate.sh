#!/bin/bash
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
J=/opt/homebrew/opt/openjdk@21/bin
p=$(adb shell pm path com.cubs.cam | tr -d '\r' | sed -n 's/^package://p' | head -1)
[ -n "$p" ] || { echo installed-app-not-found; exit 1; }
adb pull "$p" /tmp/cubs-companion-installed.apk >/dev/null
cert() { LC_ALL=C "$J/keytool" -printcert -jarfile "$1" | awk '/SHA256:/ {print $2; exit}'; }
old=$(cert /tmp/cubs-companion-installed.apk)
new=$(cert /tmp/cubs-wifi-companion-candidate.apk)
[ -n "$old" ] && [ "$old" = "$new" ] || { echo signing-certificate-mismatch; exit 1; }
echo signing-certificate-matches
"$HOME/apkbuild/aapt2" dump xmltree /tmp/cubs-wifi-companion-candidate.apk --file AndroidManifest.xml | grep -E 'com.cubs.cam.(CamService|SndService|WifiStatusService)' | wc -l | tr -d ' '
