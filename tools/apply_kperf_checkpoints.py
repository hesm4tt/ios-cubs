#!/usr/bin/env python3
"""Insert CP95 immediately before kperf_init_early() and retain a backup."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import tempfile
from datetime import datetime


DEFAULT_SOURCE = Path(
    "$HOME/unixnu-pixel11/hackios-upstream/"
    "xnu-src/xnu-8796.121.2/osfmk/kern/startup.c"
)
ANCHOR_RE = re.compile(rb"(?m)^(?P<indent>\t*)kperf_init_early\(\);\r?\n")
MARKER = b"loader_checkpoint(95);"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument(
        "--apply", action="store_true", help="write the guarded edit and backup"
    )
    args = parser.parse_args()

    source = args.source
    original = source.read_bytes()
    if MARKER in original:
        raise SystemExit("CP95 marker is already present; refusing a duplicate")
    matches = list(ANCHOR_RE.finditer(original))
    if len(matches) != 1:
        raise SystemExit(f"expected one kperf_init_early() anchor; found {len(matches)}")

    match = matches[0]
    newline = b"\r\n" if b"\r\n" in original else b"\n"
    marker_line = (
        match.group("indent")
        + MARKER
        + b" /* CUBS checkpoint before kperf_init_early(). */"
        + newline
    )
    updated = original[: match.start()] + marker_line + original[match.start() :]
    print(f"validated unique CP95 insertion point in {source}")
    if not args.apply:
        print("dry run only; pass --apply to write")
        return

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = source.with_name(f"{source.name}.pre-cubs-cp95.{stamp}")
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
