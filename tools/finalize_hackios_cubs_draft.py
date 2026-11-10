#!/usr/bin/env python3
"""Mark unresolved values explicitly in the generated HackiOS CUBS profile."""

from __future__ import annotations

import sys
from pathlib import Path


root = Path(sys.argv[1])
conf = root / "common/devices/cubs.conf"
platform = root / "common/devices/cubs.platform.c"

lines = conf.read_text(encoding="utf-8").splitlines()
replacements = {
    'NAME=': 'NAME="Google Pixel 11 (cubs)"',
    'SOC=': 'SOC="Google Tensor G6 (malibu)"',
    'FD_BASE=': 'FD_BASE=  # TODO: determine from the CUBS UEFI memory map',
    'FD_SIZE=': 'FD_SIZE=  # TODO: determine from the CUBS UEFI memory map',
    'PAYLOAD_BASE=': 'PAYLOAD_BASE=  # TODO: verify free RAM and reserved ranges',
    'FB_BASE=': 'FB_BASE=0x00000000  # TODO: use the base reported by CUBS UEFI GOP',
    'BOOTARGS=': 'BOOTARGS="cpus=7"',
}
for prefix, replacement in replacements.items():
    indexes = [i for i, line in enumerate(lines) if line.startswith(prefix)]
    if len(indexes) != 1:
        raise SystemExit(f"expected one {prefix} entry in {conf}, found {len(indexes)}")
    lines[indexes[0]] = replacement

if not any(line.startswith("# DRAFT ONLY") for line in lines):
    insert = next(i for i, line in enumerate(lines) if line.startswith("NAME="))
    lines[insert:insert] = [
        "# DRAFT ONLY: not buildable or bootable until CUBS UEFI and RAM map are resolved.",
        "# The raw vendor DTB reports only 256 MiB; the live Android tree reports multiple RAM banks.",
        "# Reconcile the final active FDT before using this DTB in any boot image.",
    ]
conf.write_text("\n".join(lines) + "\n", encoding="utf-8")

source = platform.read_text(encoding="utf-8")
old = '\t.io_base = 0x00400000, .io_size = 0x3FC00000,   /* TODO: one window over the SoC\'s peripherals, non-zero base */'
new = '\t.io_base = 0x0, .io_size = 0x0,              /* TODO: fill with verified Tensor MMIO window */'
if old not in source:
    raise SystemExit(f"expected unfilled template MMIO line was not found in {platform}")
source = source.replace(old, new, 1)
source = source.replace(
    "/*\n * cubs: paste into xnuloader/loader.c next to platform_redwood and add &platform_cubs to platforms[].\n",
    "/*\n * DRAFT ONLY: CUBS values below are incomplete; do not register or boot this platform yet.\n * cubs: paste into xnuloader/loader.c next to platform_redwood and add &platform_cubs to platforms[].\n",
    1,
)
platform.write_text(source, encoding="utf-8")
print(f"marked incomplete CUBS build inputs in {conf} and {platform}")
