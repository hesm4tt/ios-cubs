#!/bin/bash
# Sideload launch test, end to end on the Mac: a clone of the baked MetalDemo app with its own bundle id and URL scheme becomes an IPA, then a .deb in the
# phone's inbox; the test image opens the baked app (metaldemo://) and then the sideloaded clone (persisttest://) after the unlock swipe.
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
cd "$HOME"
rm -rf /tmp/pt3; mkdir -p /tmp/pt3/Payload
cp -a "$HOME/unixnu-pixel11/hackios-upstream/apps/MetalDemo.app" /tmp/pt3/Payload/PersistTest.app
cd /tmp/pt3/Payload/PersistTest.app
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.cubs.persisttest" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName PersistTest" Info.plist 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string PersistTest" Info.plist
/usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes" Info.plist | head -8
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 persisttest" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName com.cubs.persisttest" Info.plist
cd /tmp/pt3 && zip -qr persisttest.ipa Payload
bash "$HOME/ipa2deb.sh" /tmp/pt3/persisttest.ipa /tmp/pt3/persisttest.deb
adb push /tmp/pt3/persisttest.deb /data/local/tmp/persisttest.deb >/dev/null
printf 'rm -f /data/local/ios/inbox/*.deb /data/local/ios/persist.tar /data/local/ios/persist.tar.prev; cp /data/local/tmp/persisttest.deb /data/local/ios/inbox/; ls /data/local/ios/inbox\n' | adb shell /data/adb/ksu/bin/ksud debug su
cd "$HOME"
export JOBS_TAIL='/redwood/bin/rwtouch wait 20 swipe 0.5 0.985 0.5 0.3 250 wait 3
/redwood/bin/battery_test open persisttest://x
/redwood/bin/rwtouch wait 60
/bin/ps -A
/redwood/bin/rwtouch wait 30'
export IMAGE_OUTPUT="$HOME/hopay/root_cubs_sideload.apfs"
bash build_persist_image.sh
unset JOBS_TAIL
PAYLOAD_NAME=cubssl ROOT_IMAGE="$HOME/hopay/root_cubs_sideload.apfs" BOOT_EXTRA="cubs_shot=1 cubs_sound=1 cubs_hb=1" bash build_big_payload.sh
echo BUILD-OK
