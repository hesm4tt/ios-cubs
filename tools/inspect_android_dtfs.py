#!/usr/bin/env python3
"""Summarize a copied Android /sys/firmware/devicetree/base tree.

This is intentionally an inventory tool, not an FDT serializer. The sysfs tree
does not preserve the original FDT header or reservation map, so its output must
not be substituted for the device's raw DTB when building a boot image.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def read_prop(node: Path, name: str) -> bytes | None:
    path = node / name
    try:
        if path.is_file():
            return path.read_bytes()
    except OSError:
        pass
    return None


def strings(data: bytes | None) -> list[str]:
    if not data:
        return []
    return [part.decode("utf-8", errors="replace") for part in data.split(b"\0") if part]


def cells(data: bytes | None) -> list[int]:
    if not data or len(data) % 4:
        return []
    return [int.from_bytes(data[i : i + 4], "big") for i in range(0, len(data), 4)]


def cell_count(node: Path, prop: str, default: int) -> int:
    values = cells(read_prop(node, prop))
    return values[0] if len(values) == 1 else default


def reg_entries(node: Path) -> list[dict[str, str | None]]:
    raw = cells(read_prop(node, "reg"))
    parent = node.parent
    address_cells = cell_count(parent, "#address-cells", 2)
    size_cells = cell_count(parent, "#size-cells", 1)
    stride = address_cells + size_cells
    if not raw or stride <= 0 or len(raw) % stride:
        return []

    result = []
    for start in range(0, len(raw), stride):
        record = raw[start : start + stride]
        address = 0
        for word in record[:address_cells]:
            address = (address << 32) | word
        size: int | None = None
        if size_cells:
            size = 0
            for word in record[address_cells:]:
                size = (size << 32) | word
        result.append(
            {
                "base": f"0x{address:x}",
                "size": None if size is None else f"0x{size:x}",
            }
        )
    return result


def display_node(node: Path, root: Path) -> dict[str, Any]:
    try:
        name = "/" + node.relative_to(root).as_posix()
    except ValueError:
        name = str(node)
    return {
        "path": name,
        "compatible": strings(read_prop(node, "compatible")),
        "reg": reg_entries(node),
    }


def serial_node_details(node: Path, root: Path, aliases: list[str]) -> dict[str, Any]:
    """Return UART facts that affect whether a boot log can actually be used."""
    details = display_node(node, root)
    shift = cells(read_prop(node, "reg-shift"))
    io_width = cells(read_prop(node, "reg-io-width"))
    details.update(
        {
            "aliases": aliases,
            "status": strings(read_prop(node, "status")),
            "reg_shift": shift[0] if len(shift) == 1 else None,
            "reg_io_width": io_width[0] if len(io_width) == 1 else None,
            "clock_names": strings(read_prop(node, "clock-names")),
            "pinctrl_names": strings(read_prop(node, "pinctrl-names")),
        }
    )
    return details


def inspect(root: Path) -> dict[str, Any]:
    if not root.is_dir():
        raise ValueError(f"not a device-tree filesystem directory: {root}")

    nodes = [root]
    nodes.extend(path for path in root.rglob("*") if path.is_dir())
    by_compatible: list[tuple[Path, list[str]]] = [
        (node, strings(read_prop(node, "compatible"))) for node in nodes
    ]

    model = strings(read_prop(root, "model"))
    compatible = strings(read_prop(root, "compatible"))

    gic_nodes = [
        display_node(node, root)
        for node, comps in by_compatible
        if "arm,gic-v3" in comps
    ]

    cpus_dir = root / "cpus"
    cpu_nodes = []
    if cpus_dir.is_dir():
        for node in sorted(cpus_dir.iterdir()):
            if not node.is_dir() or not node.name.startswith("cpu@"):
                continue
            reg_cells = cells(read_prop(node, "reg"))
            mpidr = 0
            for word in reg_cells:
                mpidr = (mpidr << 32) | word
            capacity_cells = cells(read_prop(node, "capacity-dmips-mhz"))
            cpu_nodes.append(
                {
                    "node": node.name,
                    "mpidr": f"0x{mpidr:x}",
                    "capacity_dmips_mhz": (
                        capacity_cells[0] if len(capacity_cells) == 1 else None
                    ),
                    "enable_method": strings(read_prop(node, "enable-method")),
                    "compatible": strings(read_prop(node, "compatible")),
                    "status": strings(read_prop(node, "status")),
                }
            )

    mpidrs = [int(cpu["mpidr"], 16) for cpu in cpu_nodes]
    core_shift: int | None = None
    if mpidrs and mpidrs == [index * 0x100 for index in range(len(mpidrs))]:
        core_shift = 8
    elif mpidrs and mpidrs == list(range(len(mpidrs))):
        core_shift = 0

    capacities = [cpu["capacity_dmips_mhz"] for cpu in cpu_nodes]
    small_core_mask: int | None = None
    if core_shift is not None and capacities and all(value is not None for value in capacities):
        numeric = [int(value) for value in capacities]
        if min(numeric) < max(numeric):
            small_core_mask = sum(
                1 << (mpidr >> core_shift)
                for mpidr, capacity in zip(mpidrs, numeric)
                if capacity == min(numeric)
            )

    psci_nodes = [
        node
        for node, comps in by_compatible
        if node.name == "psci" or any(value.startswith("arm,psci") for value in comps)
    ]
    psci = []
    for node in psci_nodes:
        psci.append(
            {
                "path": "/" + node.relative_to(root).as_posix(),
                "compatible": strings(read_prop(node, "compatible")),
                "method": strings(read_prop(node, "method")),
            }
        )

    memory_nodes = []
    for node in nodes:
        if strings(read_prop(node, "device_type")) == ["memory"]:
            memory_nodes.append(display_node(node, root))

    reserved_memory_dir = root / "reserved-memory"
    reserved_memory = []
    if reserved_memory_dir.is_dir():
        for node in sorted(reserved_memory_dir.iterdir()):
            if not node.is_dir():
                continue
            reserved_memory.append(
                {
                    **display_node(node, root),
                    "no_map": read_prop(node, "no-map") is not None,
                    "reusable": read_prop(node, "reusable") is not None,
                    "status": strings(read_prop(node, "status")),
                }
            )

    ufs_nodes = [
        display_node(node, root)
        for node, comps in by_compatible
        if any("ufshc" in value.lower() for value in comps)
    ]
    gpu_nodes = [
        display_node(node, root)
        for node, comps in by_compatible
        if any("gpu" in value.lower() for value in comps)
    ]
    display_nodes = [
        display_node(node, root)
        for node, comps in by_compatible
        if any(
            token in value.lower()
            for value in comps
            for token in ("display-subsystem", "mipi-dsi", "panel-")
        )
    ]
    touch_nodes = [
        display_node(node, root)
        for node, comps in by_compatible
        if "touchscreen" in node.name.lower()
        or any(
            "touchscreen" in value.lower() or "tcm" in value.lower()
            for value in comps
        )
    ]

    aliases_dir = root / "aliases"
    alias_targets: dict[str, str] = {}
    if aliases_dir.is_dir():
        for alias_path in aliases_dir.iterdir():
            target = strings(read_prop(aliases_dir, alias_path.name))
            if target:
                alias_targets[alias_path.name] = target[0]
    serial0_target = alias_targets.get("serial0")
    serial0_node = root / serial0_target.lstrip("/") if serial0_target else None
    serial0 = (
        serial_node_details(
            serial0_node,
            root,
            sorted(name for name, target in alias_targets.items() if target == serial0_target),
        )
        if serial0_node and serial0_node.is_dir()
        else None
    )
    serial_nodes = [
        serial_node_details(
            node,
            root,
            sorted(
                name
                for name, target in alias_targets.items()
                if target == "/" + node.relative_to(root).as_posix()
            ),
        )
        for node, comps in by_compatible
        if any("uart" in value.lower() or "serial" in value.lower() for value in comps)
    ]
    chosen_dir = root / "chosen"
    chosen = {
        "bootargs": strings(read_prop(chosen_dir, "bootargs")),
        "stdout_path": strings(read_prop(chosen_dir, "stdout-path")),
        "linux_stdout_path": strings(read_prop(chosen_dir, "linux,stdout-path")),
    }

    valid_gic_regions = [
        region
        for node in gic_nodes
        for region in node["reg"]
        if region["size"] not in (None, "0x0")
    ]
    valid_ufs_regions = [
        region
        for node in ufs_nodes
        for region in node["reg"]
        if region["size"] not in (None, "0x0")
    ]
    psci_methods = [value for node in psci for value in node["method"]]

    return {
        "schema_version": 1,
        "source": "Android /sys/firmware/devicetree/base (copied with adb pull)",
        "model": model,
        "compatible": compatible,
        "hardware": {
            "cpu_count": len(cpu_nodes),
            "cpus": cpu_nodes,
            "mpidr_core_shift_candidate": core_shift,
            "min_capacity_core_mask_candidate": (
                f"0x{small_core_mask:x}" if small_core_mask is not None else None
            ),
            "cpu_capacity_classes": sorted(set(capacities)),
            "psci": psci,
            "psci_method": psci_methods,
            "gic_v3": gic_nodes,
            "memory_nodes": memory_nodes,
            "reserved_memory": reserved_memory,
            "ufs": ufs_nodes,
            "gpu": gpu_nodes,
            "display": display_nodes,
            "touch": touch_nodes,
            "serial0": serial0,
            "serial_candidates": serial_nodes,
        },
        "boot": {"chosen": chosen},
        "hackios_platform_candidates": {
            "cores": len(cpu_nodes),
            "core_shift": core_shift,
            "small_cores_min_capacity_mask": (
                f"0x{small_core_mask:x}" if small_core_mask is not None else None
            ),
            "gic_dist": valid_gic_regions[0]["base"] if valid_gic_regions else None,
            "gic_redist": valid_gic_regions[1]["base"] if len(valid_gic_regions) > 1 else None,
            "psci_hvc": 0 if psci_methods == ["smc"] else 1 if psci_methods == ["hvc"] else None,
            "ufs_controller_base": valid_ufs_regions[0]["base"] if valid_ufs_regions else None,
            "buildable": False,
            "unresolved": [
                "CUBS UEFI port and its memory map",
                "FD_BASE, FD_SIZE, and PAYLOAD_BASE for the UEFI boot shim",
                "UEFI GOP framebuffer base and layout",
                "safe SoC peripheral io_base/io_size for XNU",
                "CUBS-specific XNU display, touch, and UFS support",
                "raw FDT binary and its reservation map (not preserved by sysfs export)",
            ],
        },
        "notes": [
            "Candidate fields are derived from the live Android DT and are not yet a boot profile.",
            "The smallest capacity group is reported separately; this DT has multiple capacity classes.",
            "The sysfs tree is useful for inventory but is not a byte-identical replacement for the raw DTB.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dtfs", type=Path, help="copied Android device-tree filesystem root")
    parser.add_argument("--output", type=Path, help="write JSON inventory here instead of stdout")
    args = parser.parse_args()
    result = inspect(args.dtfs)
    rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
