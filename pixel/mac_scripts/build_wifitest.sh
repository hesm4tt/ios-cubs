#!/bin/bash
# Wi-Fi bridge test: image whose jobs unlock and open Settings > Wi-Fi, then the cubs_wifi=1 payload on it (build_wifi_payload.sh).
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
cd "$HOME"
export JOBS_TAIL='/redwood/bin/rwtouch wait 70 swipe 0.5 0.985 0.5 0.3 250 wait 3
/redwood/bin/battery_test open prefs:root=WIFI
/redwood/bin/rwtouch wait 80'
export IMAGE_OUTPUT="$HOME/hopay/root_cubs_wifitest.apfs"
bash build_persist_image.sh
unset JOBS_TAIL
PAYLOAD_NAME=cubswifit ROOT_IMAGE="$HOME/hopay/root_cubs_wifitest.apfs" bash build_wifi_payload.sh
echo BUILD-OK
