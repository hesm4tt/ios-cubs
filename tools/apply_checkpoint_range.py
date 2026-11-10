#!/usr/bin/env python3
"""Extend the direct-XNU shim and image builder checkpoint range to CP114.

Default mode validates exact source lines only. Pass --apply to edit both files;
exclusive timestamped backups are created before either file is changed.
"""

from __future__ import annotations

import argparse
from datetime import datetime
import os
from pathlib import Path
import stat
import sys


LOADER_OLD = (
    "#if CUBS_XNU_CHECKPOINT < 0 || CUBS_XNU_CHECKPOINT > 99\n"
    "#error CUBS_XNU_CHECKPOINT must be between 0 and 99"
)
LOADER_NEW = (
    "#if CUBS_XNU_CHECKPOINT < 0 || CUBS_XNU_CHECKPOINT > 114\n"
    "#error CUBS_XNU_CHECKPOINT must be between 0 and 114"
)
BUILDER_OLD = (
    "0|1|2|3|4|5|6|10|11|12|13|14|15|16|17|18|19|20|21|30|31|32|33|34|35|40|41|42|43|44|4[5-9]|[5-9][0-9]) ;;"
)
BUILDER_NEW = (
    "0|1|2|3|4|5|6|10|11|12|13|14|15|16|17|18|19|20|21|30|31|32|33|34|35|40|41|42|43|44|4[5-9]|[5-9][0-9]|10[0-9]|11[0-4]) ;;"
)
MESSAGE_OLD = "must be one of 0..6, 10..21, 30..35, or 40..99"
MESSAGE_NEW = "must be one of 0..6, 10..21, 30..35, or 40..114"


def read_text(path: Path) -> tuple[bytes, str, str]:
    raw = path.read_bytes()
    newline = "\r\n" if b"\r\n" in raw else "\n"
    return raw, raw.decode("utf-8").replace("\r\n", "\n"), newline


def validate(path: Path, original: str, old: str, new: str) -> list[str]:
    if original.count(new):
        return [f"{path}: already contains the new range text"]
    count = original.count(old)
    if count != 1:
        return [f"{path}: expected one old range anchor, found {count}"]
    return []


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("loader", type=Path, help="direct-xnu-checkpoint10/loader.c")
    parser.add_argument("builder", type=Path, help="build_cubs_xnu_image.sh")
    parser.add_argument("--apply", action="store_true", help="write changes (default: check only)")
    args = parser.parse_args()

    files = [
        (args.loader, LOADER_OLD, LOADER_NEW),
        (args.builder, BUILDER_OLD, BUILDER_NEW),
    ]
    originals: dict[Path, tuple[bytes, str, str]] = {}
    errors: list[str] = []
    for path, old, new in files:
        try:
            originals[path] = read_text(path)
        except (OSError, UnicodeDecodeError) as exc:
            errors.append(f"{path}: cannot read: {exc}")
            continue
        errors.extend(validate(path, originals[path][1], old, new))

    if not args.builder.is_file():
        errors.append(f"{args.builder}: builder is missing")
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 2

    print("validated the loader and builder checkpoint limits for CP100-CP114")
    if not args.apply:
        print("check only; pass --apply to modify both files")
        return 0

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backups: list[tuple[Path, Path]] = []
    try:
        for path, _, _ in files:
            backup = path.with_name(path.name + f".pre-cubs-cp100-114.{stamp}")
            with backup.open("xb") as stream:
                stream.write(originals[path][0])
            backups.append((path, backup))

        for path, old, new in files:
            raw, original, newline = originals[path]
            changed = original.replace(old, new, 1)
            if path == args.builder:
                if changed.count(MESSAGE_OLD) != 1:
                    raise ValueError(f"{path}: expected one builder error-message anchor")
                changed = changed.replace(MESSAGE_OLD, MESSAGE_NEW, 1)
            temp = path.with_name(path.name + ".cp100-114.tmp")
            temp.write_bytes(changed.replace("\n", newline).encode("utf-8"))
            os.chmod(temp, stat.S_IMODE(path.stat().st_mode))
            temp.replace(path)
    except (OSError, ValueError) as exc:
        print(f"error: write failed: {exc}", file=sys.stderr)
        return 2

    for path, backup in backups:
        print(f"updated {path}; backup: {backup}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
