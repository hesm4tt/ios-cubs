#!/usr/bin/env python3
"""Make HackiOS's device-profile generator work on macOS and labelled CPU nodes."""

from __future__ import annotations

import sys
from pathlib import Path


path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
backup = path.with_name(path.name + ".upstream")
if not backup.exists():
    backup.write_text(source, encoding="utf-8")

old_dtb = '[ -n "$DTB" ] && sed -i "s|^DTB=.*|DTB=$(readlink -f "$DTB")|" "$CONF"'
new_dtb = '''if [ -n "$DTB" ]; then
  DTB=$(readlink -f "$DTB") || die "cannot resolve $DTB"
  python3 - "$CONF" "$DTB" <<'PY'
from pathlib import Path
import shlex, sys
p = Path(sys.argv[1])
lines = p.read_text().splitlines()
for i, line in enumerate(lines):
    if line.startswith("DTB="):
        lines[i] = "DTB=" + shlex.quote(sys.argv[2])
        break
else:
    raise SystemExit("no DTB entry in profile")
p.write_text(chr(10).join(lines) + chr(10))
PY
fi'''
old_cpu = r"r'\n\t*cpu@([0-9a-f]+) \{(.*?)\n\t*\};'"
new_cpu = r"r'\n\t*(?:[A-Za-z_][A-Za-z0-9_]*:\s*)?cpu@([0-9a-f]+) \{(.*?)\n\t*\};'"

if old_dtb not in source:
    raise SystemExit("expected upstream DTB sed line was not found; no patch applied")
if old_cpu not in source:
    raise SystemExit("expected upstream CPU regex was not found; no patch applied")

source = source.replace(old_dtb, new_dtb).replace(old_cpu, new_cpu)
path.write_text(source, encoding="utf-8")
print(f"patched {path}; original saved at {backup}")
