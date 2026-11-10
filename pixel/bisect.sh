#!/bin/bash
# usage: bisect.sh <symbol> <tag>   (plants a cookie at the symbol in hofull.payload, runs the full boot with the watchdog armed)
export PATH=$PATH:/opt/homebrew/bin
python3 ~/patchcookie.py $1 $2 hofull.payload
bash ~/fullboot2.sh ho_patched.payload 2>&1 | tail -2
