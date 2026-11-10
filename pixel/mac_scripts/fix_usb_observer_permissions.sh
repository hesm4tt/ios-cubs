#!/bin/bash
set -eu
export PATH="$PATH:/opt/homebrew/bin"
printf '%s\n' 'set -e
D=/data/adb/modules_update/cubs_usb_observer
test -f "$D/module.prop" && test -f "$D/service.sh" && test -f "$D/observe.sh" || exit 1
chmod 755 "$D/service.sh" "$D/observe.sh" || exit 1
test -x "$D/service.sh" && test -x "$D/observe.sh" && test ! -e "$D/disable" || exit 1
echo observer-permissions-ok' | adb shell /data/adb/ksu/bin/ksud debug su
