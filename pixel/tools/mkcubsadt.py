#!/usr/bin/env python3
"""Generate a headless CUBS Apple Device Tree from the iPhone X ADT seed.

The memory interval is an explicit input because the Android runtime FDT is
not proof of the Fastboot handoff map. A RAM boot shim must validate the
selected interval against the actual x0 FDT before it writes any XNU segment.
"""

from __future__ import annotations

import argparse
import importlib.util
import struct
from pathlib import Path


HERE = Path(__file__).resolve().parent
BLUEJAY_TOOLS = HERE.parent / "references" / "ios-bluejay" / "tools"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


adt = load_module("bluejay_adt", BLUEJAY_TOOLS / "adt.py")
mkadt = load_module("bluejay_mkadt", BLUEJAY_TOOLS / "mkadt.py")


def cstr(value: str) -> bytes:
    return value.encode("ascii") + b"\0"


def set_prop(node, name: str, value: bytes) -> None:
    for i, (prop_name, flags, _) in enumerate(node.props):
        if prop_name == name:
            node.props[i] = (prop_name, flags, value)
            return
    node.props.append((name, 0, value))


def remove_props(node, names: set[str]) -> None:
    node.props = [entry for entry in node.props if entry[0] not in names]


def child(node, name: str):
    return next((c for c in node.children if c.name == name), None)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("seed", type=Path, help="raw D22AP Apple Device Tree from the iOS IPSW")
    parser.add_argument("output", type=Path, help="output raw Apple Device Tree")
    parser.add_argument("--memory-base", required=True, type=lambda s: int(s, 0))
    parser.add_argument("--memory-size", required=True, type=lambda s: int(s, 0))
    parser.add_argument("--timebase", default=999_990_000, type=int,
                        help="architected timer frequency observed by Android (default: 999.99 MHz)")
    args = parser.parse_args()

    if not args.seed.is_file():
        raise SystemExit(f"missing D22AP ADT seed: {args.seed}")
    if args.memory_base & 0x3fff or args.memory_size & 0x3fff or args.memory_size == 0:
        raise SystemExit("memory base and size must be nonzero 16 KiB aligned values")
    if args.memory_base + args.memory_size > (1 << 40):
        raise SystemExit("memory interval exceeds XNU's configured 40-bit physical range")

    # The interval is the first 6 GiB of the contiguous upper CUBS bank seen
    # in Android's runtime captures. The shim still has to verify this against
    # the actual Fastboot FDT before copying the kernel there.
    mkadt.PHYS_BASE = args.memory_base
    mkadt.MEM_SIZE = args.memory_size
    mkadt.GICD = 0x09228000
    mkadt.GICR = 0x092A8000
    mkadt.GICD_SIZE = 0x10000
    mkadt.GICR_SIZE = 0x100000
    mkadt.TIMEBASE = args.timebase
    # ARM generic timer virtual PPI 11 is INTID 16 + 11.
    mkadt.VTIMER_INTID = 27
    mkadt.D22AP_ADT = str(args.seed)
    mkadt.SWEET_ECID = 0x4355425300000001  # synthetic "CUBS" identifier
    original_product_reader = mkadt.d22ap_product

    def read_seed_product(path=None):
        return original_product_reader(str(args.seed) if path is None else path)

    # mkadt's function default captures its original seed path at definition
    # time, so pass this invocation's seed explicitly.
    mkadt.d22ap_product = read_seed_product

    root = mkadt.build()
    set_prop(root, "compatible", b"D22AP\0iPhone10,3\0google,malibu-cubs\0google,malibu\0AppleARM\0")
    set_prop(root, "model", cstr("iPhone10,3"))
    set_prop(root, "target-type", cstr("D22"))
    set_prop(root, "target-sub-type", cstr("D22AP"))

    # Keep only the seven CPUs reported by CUBS and remove Redwood/Sweet CPU
    # descriptions that are not supported by the Android capture.
    cpus = child(root, "cpus")
    if cpus is None:
        raise SystemExit("generated ADT is missing /cpus")
    cpus.children = cpus.children[:7]
    for cpu in cpus.children:
        set_prop(cpu, "compatible", cstr("ARM,v8"))
        set_prop(cpu, "timebase-frequency", struct.pack("<I", args.timebase))
        remove_props(cpu, {
            "clock-frequency", "bus-frequency", "memory-frequency",
            "peripheral-frequency", "fixed-frequency", "cluster-id",
            "cluster-type", "die-cluster-id", "cluster-core-id",
            "l2-cache-id", "l3-cache-id",
        })

    arm_io = child(root, "arm-io")
    if arm_io is None:
        raise SystemExit("generated ADT is missing /arm-io")
    set_prop(arm_io, "device_type", cstr("cubs-io"))
    set_prop(arm_io, "compatible", cstr("google,malibu-cubs") + cstr("arm-io"))
    # No CUBS framebuffer address or XNU display driver is validated yet.
    arm_io.children = [c for c in arm_io.children if c.name != "disp0"]
    root.children = [c for c in root.children if c.name not in {"sweet-fbcon", "sweet-ufs"}]

    # IOKit publishes its NVRAM object (gIOOptionsEntry) on /options. Without
    # the node, IODTPlatformExpert::processTopLevel() asserts
    # "gIOOptionsEntry != NULL" (IOPlatformExpert.cpp:1695) and panics.
    if child(root, "options") is None:
        root.children.append(mkadt.node("options"))

    # IODTNVRAM::initImageFormat() builds a CHRP handler that needs the NVRAM
    # bank description in /chosen; a missing property makes it panic with
    # "IONVRAMCHRPHandler creation failed". There is no NVRAM backing store yet,
    # so describe an empty one (zero-size bank, no proxy data): the handler then
    # initialises with an empty variable dictionary.
    chosen = child(root, "chosen")
    if chosen is None:
        raise SystemExit("generated ADT is missing /chosen")
    for key in ("nvram-bank-size", "nvram-bank-count", "nvram-current-bank"):
        set_prop(chosen, key, struct.pack("<I", 0))

    # Do not present an unknown framebuffer or an unported Tensor UFS host as
    # working hardware to XNU. A RAM-disk boot can add its own memory-map node.
    blob = adt.serialize(root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(blob)
    print(f"{args.output}: {len(blob)} bytes")
    print(f"memory: {args.memory_base:#x}+{args.memory_size:#x} (Fastboot FDT validation required)")
    print(f"cpus: {len(cpus.children)}; GICD={mkadt.GICD:#x}; GICR={mkadt.GICR:#x}; timer={args.timebase} Hz")
    print("display and UFS nodes omitted; framebuffer boot_args must remain zero")


if __name__ == "__main__":
    main()
