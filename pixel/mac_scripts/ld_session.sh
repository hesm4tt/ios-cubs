#!/bin/bash
# One iOS session for pairing tests from the Mac's Finder (run on the Mac, phone in Android with the stock gadget):
#   1. starts the supervised iOS boot with lockdownd (run_lockdown.sh, 700 s)
#   2. 130 s later, when the iOS launcher has finished with the USB stack, applies the usbmux gadget (keep flag set at once)
#   3. polls: is iOS's lockdownd listening on 10.77.0.2:62078 (nc from Android), what does the Mac's usbmuxd see
# Prints one line per poll; "READY-FOR-TRUST" when the Mac can reach iOS's real lockdownd.
export PATH="$PATH:/opt/homebrew/bin"
cd "$HOME"
nohup bash run_lockdown.sh > /tmp/run_ld.log 2>&1 &
sleep 130
rootsh() { printf '%s\n' "$1" | adb shell /data/adb/ksu/bin/ksud debug su; }
rootsh 'nohup sh /data/local/tmp/usbmux_gadget.sh apply > /data/local/tmp/usbmux_apply.log 2>&1 & sleep 2; touch /data/local/tmp/usbmux.keep' >/dev/null 2>&1
echo "$(date +%T) gadget applied"
for i in $(seq 1 40); do
  sleep 15
  l=$(rootsh 'nc -z -w2 10.77.0.2 62078 && echo LISTENING || echo closed' 2>/dev/null | tail -1)
  m=$(python3 usbmux_list.py lockdown 2>&1 | tail -3 | tr '\n' ' ' | cut -c1-200)
  echo "$(date +%T) ios:62078 $l | mac: $m"
  case "$l" in *LISTENING*) case "$m" in *"iOS port"*) ;; *"GetValue DeviceName"*) echo "READY-FOR-TRUST";; esac;; esac
  pgrep -f run_guarded.sh >/dev/null || break
done
