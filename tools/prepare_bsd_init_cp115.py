#!/usr/bin/env python3
"""Add a guarded CP115 marker after knote_init and extend shim selection to 115.

The script preflights every source anchor before changing any file, creates
timestamped exclusive backups, preserves newline style and file modes, and
fails if the expected source state has drifted.
"""

from __future__ import annotations

import argparse
from datetime import datetime
import os
from pathlib import Path
import stat
import sys


def transform(source: str, anchor: str, replacement: str, label: str) -> str:
    count = source.count(anchor)
    if count != 1:
        raise ValueError(f"{label}: expected one anchor, found {count}")
    return source.replace(anchor, replacement, 1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bsd_init", type=Path)
    parser.add_argument("loader_c", type=Path)
    parser.add_argument("image_builder", type=Path)
    args = parser.parse_args()

    try:
        original_bytes = {path: path.read_bytes() for path in (args.bsd_init, args.loader_c, args.image_builder)}
        original_text = {path: original_bytes[path].decode("utf-8") for path in original_bytes}
    except (OSError, UnicodeDecodeError) as exc:
        print(f"error: cannot read inputs: {exc}", file=sys.stderr)
        return 2

    bsd = original_text[args.bsd_init]
    if any(f"loader_checkpoint({n})" not in bsd for n in range(100, 115)):
        print("error: bsd_init.c does not contain the expected CP100-CP114 baseline", file=sys.stderr)
        return 2
    if "loader_checkpoint(115)" in bsd:
        print("error: CP115 is already present", file=sys.stderr)
        return 2

    transformed: dict[Path, str] = {}
    try:
        transformed[args.bsd_init] = transform(
            bsd,
            "\tknote_init();",
            "\tknote_init();\n\t/* CUBS bring-up checkpoint 115: after knote_init. */\n\tloader_checkpoint(115);",
            "bsd_init knote_init",
        )
        transformed[args.loader_c] = transform(
            original_text[args.loader_c],
            "#if CUBS_XNU_CHECKPOINT < 0 || CUBS_XNU_CHECKPOINT > 114\n#error CUBS_XNU_CHECKPOINT must be between 0 and 114",
            "#if CUBS_XNU_CHECKPOINT < 0 || CUBS_XNU_CHECKPOINT > 115\n#error CUBS_XNU_CHECKPOINT must be between 0 and 115",
            "loader checkpoint limit",
        )
        transformed[args.image_builder] = transform(
            original_text[args.image_builder],
            "|11[0-4]) ;;",
            "|11[0-5]) ;;",
            "image-builder checkpoint whitelist",
        )
        transformed[args.image_builder] = transform(
            transformed[args.image_builder],
            "or 40..114",
            "or 40..115",
            "image-builder range diagnostic",
        )
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backups: dict[Path, Path] = {}
    temps: dict[Path, Path] = {}
    try:
        for path, data in original_bytes.items():
            backup = path.with_name(f"{path.name}.pre-cubs-cp115.{stamp}")
            with backup.open("xb") as stream:
                stream.write(data)
            backups[path] = backup

        for path, new_text in transformed.items():
            data = new_text.encode("utf-8")
            newline = b"\r\n" if b"\r\n" in original_bytes[path] else b"\n"
            if newline == b"\r\n":
                data = new_text.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8")
            temp = path.with_name(f"{path.name}.cp115.tmp")
            if temp.exists():
                raise FileExistsError(f"temporary file already exists: {temp}")
            temp.write_bytes(data)
            os.chmod(temp, stat.S_IMODE(path.stat().st_mode))
            temps[path] = temp

        for path, temp in temps.items():
            temp.replace(path)
    except OSError as exc:
        print(f"error: update failed: {exc}", file=sys.stderr)
        return 2

    for path, backup in backups.items():
        print(f"updated {path}; backup={backup}")
    print("CP115 is after knote_init; shim selection limit is 115")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
