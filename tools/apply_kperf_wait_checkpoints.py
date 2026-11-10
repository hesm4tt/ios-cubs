#!/usr/bin/env python3
"""Bracket kperf_init_early()'s ml_wait_max_cpus() with CP96 and CP97."""

from __future__ import annotations

import argparse
from datetime import datetime
import os
from pathlib import Path
import re
import tempfile


DEFAULT_SOURCE = Path(
    "$HOME/unixnu-pixel11/hackios-upstream/"
    "xnu-src/xnu-8796.121.2/osfmk/kperf/kperf.c"
)
FUNCTION = re.compile(rb"(?m)^void\r?\nkperf_init_early\(void\)\r?\n\{")
WAIT = re.compile(rb"(?m)^(?P<indent>\t*)ml_wait_max_cpus\(\);\r?\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument(
        "--apply", action="store_true", help="write the guarded edit and backup"
    )
    args = parser.parse_args()

    source = args.source
    original = source.read_bytes()
    if b"loader_checkpoint(96);" in original or b"loader_checkpoint(97);" in original:
        raise SystemExit("CP96/CP97 already present; refusing duplicate markers")
    functions = list(FUNCTION.finditer(original))
    waits = list(WAIT.finditer(original))
    if len(functions) != 1 or len(waits) != 1:
        raise SystemExit(
            f"expected one kperf_init_early() and one wait anchor; "
            f"found functions={len(functions)} waits={len(waits)}"
        )
    if not functions[0].start() < waits[0].start():
        raise SystemExit("ml_wait_max_cpus() anchor is not inside kperf_init_early()")

    newline = b"\r\n" if b"\r\n" in original else b"\n"
    prototype_anchor = functions[0].start()
    prototype = b"extern void loader_checkpoint(uint64_t n);" + newline + newline
    with_prototype = original[:prototype_anchor] + prototype + original[prototype_anchor:]
    wait_match = next(WAIT.finditer(with_prototype))
    indent = wait_match.group("indent")
    insertion = (
        indent + b"loader_checkpoint(96); /* immediately before CPU-count wait */" + newline
        + indent + b"ml_wait_max_cpus();" + newline
        + indent + b"loader_checkpoint(97); /* immediately after CPU-count wait */" + newline
    )
    updated = with_prototype[: wait_match.start()] + insertion + with_prototype[wait_match.end() :]
    print(f"validated unique kperf CPU-count wait in {source}")
    if not args.apply:
        print("dry run only; pass --apply to write")
        return

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = source.with_name(f"{source.name}.pre-cubs-cp96-97.{stamp}")
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
