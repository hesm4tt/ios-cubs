#!/bin/bash
set -euo pipefail
cd "$HOME/unixnu-pixel11/hackios-upstream"
source ./xnu-env.sh
export THEOS="$HOME/unixnu-pixel11/theos"
xnu-clang -arch arm64 -isysroot "$THEOS/sdks/iPhoneOS16.5.sdk" -O1 \
  -dynamiclib -install_name /redwood/bin/libcubs-about.dylib -undefined dynamic_lookup \
  -framework CoreFoundation -framework UIKit -I/tmp -o /tmp/libcubs-about.dylib /tmp/about_identity.c /tmp/about_display.m
echo ios-about-library-built
