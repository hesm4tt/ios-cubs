#!/usr/bin/env python3
"""Safely add CUBS diagnostic checkpoints CP100-CP114 to XNU bsd_init.c.

Default mode only checks that every source anchor is unique and that the
checkpoint calls are not already present. Pass --apply to edit the supplied
file; an exclusive backup is created beside it first.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys
from datetime import datetime
import stat


REPLACEMENTS = [
    (
        "#if (DEVELOPMENT || DEBUG)\n\tplatform_stall_panic_or_spin(PLATFORM_STALL_XNU_LOCATION_BSD_INIT);",
        "/* CUBS bring-up checkpoint 100: bsd_init entry. */\n\tloader_checkpoint(100);\n\n#if (DEVELOPMENT || DEBUG)\n\tplatform_stall_panic_or_spin(PLATFORM_STALL_XNU_LOCATION_BSD_INIT);",
        "CP100 before the optional bsd_init stall hook",
    ),
    (
        "\tthrottle_init();",
        "\tthrottle_init();\n\t/* CUBS bring-up checkpoint 101. */\n\tloader_checkpoint(101);",
        "CP101 after throttle_init",
    ),
    (
        "\tkauth_init();",
        "\tkauth_init();\n\t/* CUBS bring-up checkpoint 102. */\n\tloader_checkpoint(102);",
        "CP102 after kauth_init",
    ),
    (
        '\tprocess_name("kernel_task", kernproc);',
        '\tprocess_name("kernel_task", kernproc);\n\t/* CUBS bring-up checkpoint 103. */\n\tloader_checkpoint(103);',
        "CP103 after process_name",
    ),
    (
        "\tut = current_uthread();",
        "\tut = current_uthread();\n\t/* CUBS bring-up checkpoint 104. */\n\tloader_checkpoint(104);",
        "CP104 after current_uthread",
    ),
    (
        "\tproc_update_creds_onproc(kernproc);",
        "\tproc_update_creds_onproc(kernproc);\n\t/* CUBS bring-up checkpoint 105. */\n\tloader_checkpoint(105);",
        "CP105 after kernel credential setup",
    ),
    (
        "\t    VM_KERN_MEMORY_BSD).kmr_submap;",
        "\t    VM_KERN_MEMORY_BSD).kmr_submap;\n\t/* CUBS bring-up checkpoint 106. */\n\tloader_checkpoint(106);",
        "CP106 after kmem_suballoc",
    ),
    (
        "\tbsd_bufferinit();",
        "\tbsd_bufferinit();\n\t/* CUBS bring-up checkpoint 107. */\n\tloader_checkpoint(107);",
        "CP107 after bsd_bufferinit",
    ),
    (
        "\tIOKitInitializeTime();",
        "\tIOKitInitializeTime();\n\t/* CUBS bring-up checkpoint 108. */\n\tloader_checkpoint(108);",
        "CP108 after IOKitInitializeTime",
    ),
    (
        "\tvfsinit();",
        "\tvfsinit();\n\t/* CUBS bring-up checkpoint 109. */\n\tloader_checkpoint(109);",
        "CP109 after vfsinit",
    ),
    (
        "\tpsem_cache_init();",
        "\tpsem_cache_init();\n\t/* CUBS bring-up checkpoint 110. */\n\tloader_checkpoint(110);",
        "CP110 after psem_cache_init",
    ),
    (
        "\tsysctl_mib_init();",
        "\tsysctl_mib_init();\n\t/* CUBS bring-up checkpoint 111. */\n\tloader_checkpoint(111);",
        "CP111 after sysctl_mib_init",
    ),
    (
        "\tbsd_autoconf();",
        "\tbsd_autoconf();\n\t/* CUBS bring-up checkpoint 112. */\n\tloader_checkpoint(112);",
        "CP112 after bsd_autoconf",
    ),
    (
        "\tinittodr(0);",
        "\tinittodr(0);\n\t/* CUBS bring-up checkpoint 113. */\n\tloader_checkpoint(113);",
        "CP113 after inittodr",
    ),
    (
        "\t\tif (0 == (err = vfs_mountroot())) {",
        "\t\terr = vfs_mountroot();\n\t\t/* CUBS bring-up checkpoint 114: mountroot returned. */\n\t\tloader_checkpoint(114);\n\t\tif (0 == err) {",
        "CP114 immediately after vfs_mountroot returns",
    ),
]

DECLARATION_ANCHOR = "#include <net/init.h>"
DECLARATION = "\n\n/* CUBS early-boot diagnostic hook. */\nextern void loader_checkpoint(uint64_t n);"


def prepare(source: str) -> tuple[str | None, list[str]]:
    diagnostics: list[str] = []
    if "loader_checkpoint(1" in source:
        diagnostics.append("source already contains a loader_checkpoint(1xx) call")
    if source.count(DECLARATION_ANCHOR) != 1:
        diagnostics.append(
            f"expected one declaration anchor {DECLARATION_ANCHOR!r}, "
            f"found {source.count(DECLARATION_ANCHOR)}"
        )
    for old, _, label in REPLACEMENTS:
        count = source.count(old)
        if count != 1:
            diagnostics.append(f"{label}: expected one anchor, found {count}")
    if diagnostics:
        return None, diagnostics

    result = source.replace(DECLARATION_ANCHOR, DECLARATION_ANCHOR + DECLARATION, 1)
    for old, new, _ in REPLACEMENTS:
        result = result.replace(old, new, 1)
    missing = [n for n in range(100, 115) if f"loader_checkpoint({n})" not in result]
    if missing:
        return None, [f"internal error: generated source lacks checkpoints {missing}"]
    return result, []


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="path to the active bsd_init.c")
    parser.add_argument("--apply", action="store_true", help="write changes (default: check only)")
    args = parser.parse_args()

    try:
        original_bytes = args.source.read_bytes()
        newline = "\r\n" if b"\r\n" in original_bytes else "\n"
        original = original_bytes.decode("utf-8").replace("\r\n", "\n")
    except (OSError, UnicodeDecodeError) as exc:
        print(f"error: cannot read {args.source}: {exc}", file=sys.stderr)
        return 2

    prepared, diagnostics = prepare(original)
    if diagnostics:
        for item in diagnostics:
            print(f"error: {item}", file=sys.stderr)
        return 2

    print(f"validated {len(REPLACEMENTS)} unique bsd_init anchors in {args.source}")
    if not args.apply:
        print("check only; pass --apply to modify the source")
        return 0

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = args.source.with_name(args.source.name + f".pre-cubs-cp100-114.{stamp}")
    try:
        with backup.open("xb") as stream:
            stream.write(original_bytes)
        mode = stat.S_IMODE(args.source.stat().st_mode)
        temp = args.source.with_name(args.source.name + ".cp100-114.tmp")
        temp.write_bytes(prepared.replace("\n", newline).encode("utf-8"))
        os.chmod(temp, mode)
        temp.replace(args.source)
    except OSError as exc:
        print(f"error: write failed: {exc}", file=sys.stderr)
        return 2

    print(f"applied CP100-CP114; backup: {backup}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
