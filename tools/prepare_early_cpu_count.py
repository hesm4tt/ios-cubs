#!/usr/bin/env python3
"""Publish the known single-CPU diagnostic count before BSD waits for it."""

from __future__ import annotations

from datetime import datetime
import os
from pathlib import Path
import stat
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} KPERF_C", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    try:
        raw = path.read_bytes()
        text = raw.decode("utf-8").replace("\r\n", "\n")
    except (OSError, UnicodeDecodeError) as exc:
        print(f"error: cannot read {path}: {exc}", file=sys.stderr)
        return 2

    old = """void
kperf_init_early(void)
{
\t/*
\t * kperf allocates based on the number of CPUs and requires them to all be
\t * accounted for.
\t */
\tboolean_t found_kperf = FALSE;
\tchar kperf_config_str[64];
\tfound_kperf = PE_parse_boot_arg_str("kperf", kperf_config_str, sizeof(kperf_config_str));
\tif (found_kperf && kperf_config_str[0] != '\\0') {
\t\t/* The platform CPU driver publishes the final CPU count during enumeration. */
\t\tml_wait_max_cpus();
\t\tkperf_kernel_configure(kperf_config_str);
\t}
}
"""
    new = """void
kperf_init_early(void)
{
\t/*
\t * The CUBS diagnostic requests one CPU, and machine_info already reflects
\t * that parsed topology here. Publish that known count before BSD consumers
\t * wait for GenericARMPE, which starts later during IOKit initialization.
\t */
\tunsigned int requested_cpus = 0;
\tif (PE_parse_boot_argn("cpus", &requested_cpus, sizeof(requested_cpus)) &&
\t    requested_cpus == 1 && machine_info.max_cpus == 1) {
\t\tml_set_max_cpus(machine_info.max_cpus);
\t}

\t/* Preserve the ordinary synchronization for all other boot configurations. */
\tml_wait_max_cpus();

\tboolean_t found_kperf = FALSE;
\tchar kperf_config_str[64];
\tfound_kperf = PE_parse_boot_arg_str("kperf", kperf_config_str, sizeof(kperf_config_str));
\tif (found_kperf && kperf_config_str[0] != '\\0') {
\t\tkperf_kernel_configure(kperf_config_str);
\t}
}
"""
    if text.count(old) != 1:
        print("error: expected exactly one current optional-wait kperf_init_early body", file=sys.stderr)
        return 2

    updated = text.replace(old, new, 1)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = path.with_name(f"{path.name}.pre-cubs-early-max-cpus.{stamp}")
    temp = path.with_name(f"{path.name}.early-max-cpus.tmp")
    try:
        with backup.open("xb") as stream:
            stream.write(raw)
        data = updated.encode("utf-8")
        if b"\r\n" in raw:
            data = updated.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8")
        with temp.open("xb") as stream:
            stream.write(data)
        os.chmod(temp, stat.S_IMODE(path.stat().st_mode))
        temp.replace(path)
    except OSError as exc:
        print(f"error: update failed: {exc}", file=sys.stderr)
        return 2

    print(f"updated {path}; backup={backup}")
    print("single-CPU cpus=1 boots publish machine_info.max_cpus before the original wait")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
