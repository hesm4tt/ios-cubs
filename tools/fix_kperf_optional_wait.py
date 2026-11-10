#!/usr/bin/env python3
"""Avoid waiting for CPU registration when kperf is not requested at boot.

The normal CUBS diagnostic boot has no `kperf=` argument. On ARM,
ml_wait_max_cpus() blocks until the platform CPU driver calls ml_set_max_cpus();
that driver may be started later during platform enumeration. Keep the wait for
explicit kperf configurations, which allocate state using the final CPU count.
"""

from __future__ import annotations

import argparse
from datetime import datetime
import os
from pathlib import Path
import tempfile


DEFAULT_SOURCE = Path(
    "$HOME/unixnu-pixel11/hackios-upstream/"
    "xnu-src/xnu-8796.121.2/osfmk/kperf/kperf.c"
)
OLD_BODY = b"""\tloader_checkpoint(96); /* immediately before CPU-count wait */
\tml_wait_max_cpus();
\tloader_checkpoint(97); /* immediately after CPU-count wait */

\tboolean_t found_kperf = FALSE;
\tchar kperf_config_str[64];
\tfound_kperf = PE_parse_boot_arg_str("kperf", kperf_config_str, sizeof(kperf_config_str));
\tif (found_kperf && kperf_config_str[0] != '\\0') {
\t\tkperf_kernel_configure(kperf_config_str);
\t}
"""
NEW_BODY = b"""\tboolean_t found_kperf = FALSE;
\tchar kperf_config_str[64];
\tfound_kperf = PE_parse_boot_arg_str("kperf", kperf_config_str, sizeof(kperf_config_str));
\tif (found_kperf && kperf_config_str[0] != '\\0') {
\t\t/* The platform CPU driver publishes the final CPU count during enumeration. */
\t\tml_wait_max_cpus();
\t\tkperf_kernel_configure(kperf_config_str);
\t}
"""
PROTOTYPE = b"extern void loader_checkpoint(uint64_t n);\n\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument(
        "--apply", action="store_true", help="write the guarded edit and backup"
    )
    args = parser.parse_args()

    source = args.source
    original = source.read_bytes()
    newline = b"\r\n" if b"\r\n" in original else b"\n"
    old_body = OLD_BODY.replace(b"\n", newline)
    prototype = PROTOTYPE.replace(b"\n", newline)
    if original.count(old_body) != 1:
        raise SystemExit(
            f"expected one instrumented kperf wait block; found {original.count(old_body)}"
        )
    if original.count(prototype) != 1:
        raise SystemExit(
            f"expected one checkpoint prototype; found {original.count(prototype)}"
        )

    updated = original.replace(old_body, NEW_BODY.replace(b"\n", newline), 1)
    updated = updated.replace(prototype, b"", 1)
    print(f"validated optional-kperf wait change in {source}")
    if not args.apply:
        print("dry run only; pass --apply to write")
        return

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = source.with_name(f"{source.name}.pre-optional-kperf-wait.{stamp}")
    backup.write_bytes(original)
    os.chmod(backup, source.stat().st_mode)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{source.name}.", dir=source.parent)
    try:
        with os.fdopen(descriptor, "wb") as temporary:
            temporary.write(updated)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_name, source.stat().st_mode)
        os.replace(temporary_name, source)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise
    print(f"updated {source}")
    print(f"backup {backup}")


if __name__ == "__main__":
    main()
