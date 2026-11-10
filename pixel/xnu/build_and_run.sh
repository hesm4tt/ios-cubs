#!/bin/bash
# Run on the Mac. usage: build_and_run.sh NAME "JOBS" "EXTRA files (in $HOME)" [WAIT]
#   NAME  payload/image name stem (e.g. mh3);  JOBS  lines of the launchd job list (separated by ';');
#   EXTRA files to put into /redwood/bin; WAIT seconds before the XNU log and the panel are read.
# Builds the iOS programs' root image, the XNU payload (cmdline without the in-kernel GPU client), recomputes the RAM offsets,
# points ag4.sh (the AMP + GPU server run) at the new payload and starts the run.
export PATH=$PATH:/opt/homebrew/bin
NAME=$1; JOBS=$2; EXTRA_FILES=$3; WAIT=${4:-240}
cd ~/unixnu-pixel11/hackios-upstream/userland
export THEOS=$HOME/unixnu-pixel11/theos
[ -f ~/inject_all.txt ] && export INJECT="$(cat ~/inject_all.txt)"
echo "$JOBS" | tr ';' '\n' > rc.jobs.gpuc
cat rc.jobs.gpuc
EXTRA=$(for f in $EXTRA_FILES; do echo -n "$HOME/$f "; done)
RC_JOBS=rc.jobs.gpuc EXTRA="$EXTRA" bash build.sh > ~/userland_build_$NAME.log 2>&1; echo "userland exit $?"
cp root.apfs ~/hopay/root_$NAME.apfs
cd ~
ROOT=$HOME/hopay/root_$NAME.apfs ~/mac_build.sh $NAME.payload "debug=0x8 keepsyms=1 cpus=1 rd=md0 loader_return_after=100000 cubs_blit=3 cubs_touch=1 cubs_touch_div=16 $CMDEXTRA" 2>&1 | tail -1
cd ~/pcwork && python3 bootreg.py ~/hopay/$NAME.payload hopay2/${NAME}r.payload 0x600
cd ~
python3 - <<XX
import struct, re
d = open("$HOME/hopay/$NAME.payload", "rb").read(80)
vb, en, ao, asz, ke, pb, ms = struct.unpack_from("<7Q", d, 16)
ram = (ke - vb) - ((2492203008 + 0x3fff) & ~0x3fff)
lst = ms - 0x100000
s = open("$HOME/ag4.sh").read()
s = re.sub(r"RAMOFF=[0-9a-f]+ LISTOFF=[0-9a-f]+ WAIT=[0-9]+", "RAMOFF=%x LISTOFF=%x WAIT=$WAIT" % (ram, lst), s)
s = re.sub(r"[A-Za-z0-9]+r\.payload", "${NAME}r.payload", s)
open("$HOME/ag4.sh", "w").write(s)
print("ag4:", re.findall(r"RAMOFF=\S+ LISTOFF=\S+ WAIT=\S+", s), re.findall(r"[A-Za-z0-9]+r\.payload", s)[:1])
XX
for i in $(seq 1 60); do [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break; sleep 5; done
adb shell "rm -f /data/local/tmp/carve.bin /data/local/tmp/fbdump.raw /data/local/tmp/amp_temps.log"
bash ~/ag4.sh | tail -1
