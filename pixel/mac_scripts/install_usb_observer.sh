#!/bin/bash
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
T=$(mktemp -d /tmp/cubs-usb-module.XXXXXX)
cleanup() { rm -rf "$T"; adb shell rm -f /data/local/tmp/cubs-usb-observer.zip >/dev/null 2>&1 || :; }
trap cleanup EXIT
cp /tmp/module.prop /tmp/service.sh /tmp/observe.sh /tmp/customize.sh "$T/"
chmod 755 "$T/service.sh" "$T/observe.sh"
(cd "$T" && zip -q /tmp/cubs-usb-observer.zip module.prop service.sh observe.sh customize.sh)
adb push /tmp/cubs-usb-observer.zip /data/local/tmp/cubs-usb-observer.zip >/dev/null
printf '%s\n' 'test ! -e /data/adb/modules/cubs_usb_observer || exit 1
/data/adb/ksu/bin/ksud module install /data/local/tmp/cubs-usb-observer.zip' | adb shell /data/adb/ksu/bin/ksud debug su
printf '%s\n' 'D=/data/adb/modules_update/cubs_usb_observer
test -f "$D/module.prop" && test -x "$D/service.sh" && test -x "$D/observe.sh" && test ! -e "$D/disable" && echo observer-staged' | adb shell /data/adb/ksu/bin/ksud debug su
rm -f /tmp/cubs-usb-observer.zip
