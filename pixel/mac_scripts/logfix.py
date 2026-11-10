#!/usr/bin/env python3
"""logfix.py kernel-log.bin > linear.txt : the /dev/cubs_log ring is read from offset 0 but wraps; rotate it at the point where the
timestamps jump back (newest text ends there, the oldest starts), and print only the text lines in time order."""
import re, sys
d = open(sys.argv[1], 'rb').read()
d = d[:len(d.rstrip(b'\0'))]
last = None
cut = 0
for m in re.finditer(rb"\[ *(\d+\.\d+)\]: ", d):
    t = float(m.group(1))
    if last is not None and t < last - 1:
        cut = m.start()
        break
    last = t
d = d[cut:] + d[:cut] if cut else d
sys.stdout.buffer.write(re.sub(rb"[^\x09\x0a\x20-\x7e]", b"", d.replace(b"\0", b"")).replace(b"\n[", b"\n["))
