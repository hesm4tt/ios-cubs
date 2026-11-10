#!/usr/bin/env python3
"""Add CP117 after proc_uuid_policy_init and extend CUBS shim selection."""

from __future__ import annotations

from datetime import datetime
import os
from pathlib import Path
import stat
import sys


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise ValueError(f"{label}: expected one anchor, found {count}")
    return text.replace(old, new, 1)


def main() -> int:
    if len(sys.argv) != 4:
        print(f"usage: {Path(sys.argv[0]).name} BSD_INIT_C LOADER_C IMAGE_BUILDER", file=sys.stderr)
        return 2
    paths = [Path(arg) for arg in sys.argv[1:]]
    try:
        raw = {path: path.read_bytes() for path in paths}
        newlines = {path: b"\r\n" if b"\r\n" in raw[path] else b"\n" for path in paths}
        text = {path: raw[path].decode("utf-8").replace("\r\n", "\n") for path in paths}
    except (OSError, UnicodeDecodeError) as exc:
        print(f"error: cannot read inputs: {exc}", file=sys.stderr)
        return 2

    bsd, loader, builder = paths
    if any(f"loader_checkpoint({n})" not in text[bsd] for n in range(100, 117)):
        print("error: expected CP100-CP116 baseline is missing", file=sys.stderr)
        return 2
    if "loader_checkpoint(117)" in text[bsd]:
        print("error: CP117 is already present", file=sys.stderr)
        return 2

    updated: dict[Path, str] = {}
    try:
        updated[bsd] = replace_once(
            text[bsd],
            "\tproc_uuid_policy_init();",
            "\tproc_uuid_policy_init();\n\t/* CUBS bring-up checkpoint 117: after proc_uuid_policy_init. */\n\tloader_checkpoint(117);",
            "bsd_init proc_uuid_policy_init",
        )
        updated[loader] = replace_once(
            text[loader],
            "#if CUBS_XNU_CHECKPOINT < 0 || CUBS_XNU_CHECKPOINT > 116\n#error CUBS_XNU_CHECKPOINT must be between 0 and 116",
            "#if CUBS_XNU_CHECKPOINT < 0 || CUBS_XNU_CHECKPOINT > 117\n#error CUBS_XNU_CHECKPOINT must be between 0 and 117",
            "loader checkpoint limit",
        )
        updated[builder] = replace_once(
            text[builder],
            "|11[0-6]) ;;",
            "|11[0-7]) ;;",
            "image-builder checkpoint whitelist",
        )
        updated[builder] = replace_once(
            updated[builder],
            "or 40..116",
            "or 40..117",
            "image-builder range diagnostic",
        )
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backups: dict[Path, Path] = {}
    temps: dict[Path, Path] = {}
    try:
        for path in paths:
            backup = path.with_name(f"{path.name}.pre-cubs-cp117.{stamp}")
            with backup.open("xb") as stream:
                stream.write(raw[path])
            backups[path] = backup
        for path in paths:
            temp = path.with_name(f"{path.name}.cp117.tmp")
            if temp.exists():
                raise FileExistsError(f"temporary file already exists: {temp}")
            data = updated[path].encode("utf-8")
            if newlines[path] == b"\r\n":
                data = updated[path].replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8")
            temp.write_bytes(data)
            os.chmod(temp, stat.S_IMODE(path.stat().st_mode))
            temps[path] = temp
        for path in paths:
            temps[path].replace(path)
    except OSError as exc:
        print(f"error: update failed: {exc}", file=sys.stderr)
        return 2

    for path in paths:
        print(f"updated {path}; backup={backups[path]}")
    print("CP117 is after proc_uuid_policy_init; shim selection limit is 117")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
