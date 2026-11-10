#!/usr/bin/env python3
"""Repack a CUBS ARM64 Image into an Android boot v4 image using legacy LZ4.

The input boot image is used only as the verified CUBS v4 header template.
The script requires its current kernel section to equal the supplied Image,
then changes only the kernel-size field and kernel bytes. It round-trips the
legacy-LZ4 stream through MagiskBoot before writing the final package.
"""

from __future__ import annotations

import argparse
import hashlib
import struct
import subprocess
import tempfile
from pathlib import Path


PAGE_SIZE = 4096
BOOT_V4_HEADER_SIZE = 1584
IMAGE_HEADER_SIZE = 64
IMAGE_MAGIC = b"ARM\x64"


def fail(message: str) -> None:
    raise SystemExit(f"pack_cubs_lz4_bootv4: {message}")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run_magiskboot(tool: Path, *args: str) -> None:
    result = subprocess.run([str(tool), *args], text=True, capture_output=True)
    if result.returncode:
        fail(
            f"MagiskBoot {' '.join(args[:1])} failed ({result.returncode}): "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )


def validate_image(image: bytes) -> None:
    if len(image) < IMAGE_HEADER_SIZE:
        fail("input ARM64 Image is shorter than its header")
    if image[56:60] != IMAGE_MAGIC:
        fail("input does not contain an ARM64 Image magic value")
    text_offset, image_size, flags = struct.unpack_from("<3Q", image, 8)
    if image_size != len(image):
        fail(f"ARM64 Image size field {image_size:#x} != file size {len(image):#x}")
    if text_offset != 0 or flags != 0xA:
        fail(f"unexpected CUBS Image header: text_offset={text_offset:#x}, flags={flags:#x}")


def validate_template(template: bytes, image: bytes) -> bytearray:
    if len(template) < PAGE_SIZE or template[:8] != b"ANDROID!":
        fail("template is not a complete Android boot image")
    kernel_size, ramdisk_size = struct.unpack_from("<2I", template, 8)
    header_size = struct.unpack_from("<I", template, 20)[0]
    header_version = struct.unpack_from("<I", template, 40)[0]
    signature_size = struct.unpack_from("<I", template, 1580)[0]
    if (header_version, header_size) != (4, BOOT_V4_HEADER_SIZE):
        fail(f"expected Android boot v4/header_size 1584, got v{header_version}/{header_size}")
    if ramdisk_size != 0 or signature_size != 0:
        fail(f"template must have no ramdisk/signature; got {ramdisk_size}/{signature_size}")
    if template[44:1580].split(b"\0", 1)[0] != b"":
        fail("template command line is not empty")
    old_end = PAGE_SIZE + ((kernel_size + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1))
    if old_end != len(template):
        fail(f"template length {len(template):#x} != expected {old_end:#x}")
    if kernel_size != len(image) or template[PAGE_SIZE:PAGE_SIZE + kernel_size] != image:
        fail("template kernel is not byte-identical to the supplied ARM64 Image")
    if any(template[PAGE_SIZE + kernel_size:old_end]):
        fail("template kernel padding is not zero")
    return bytearray(template[:PAGE_SIZE])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path, help="host-verified raw ARM64 Image")
    parser.add_argument("template", type=Path, help="Android boot v4 package containing that Image")
    parser.add_argument("output_kernel", type=Path, help="path for the compressed kernel section")
    parser.add_argument("output_boot", type=Path, help="path for the compressed Android boot v4 package")
    parser.add_argument("--magiskboot", type=Path, required=True, help="MagiskBoot executable")
    args = parser.parse_args()

    image = args.image.read_bytes()
    template = args.template.read_bytes()
    validate_image(image)
    header = validate_template(template, image)
    if not args.magiskboot.is_file():
        fail(f"MagiskBoot executable not found: {args.magiskboot}")
    args.output_kernel.parent.mkdir(parents=True, exist_ok=True)
    args.output_boot.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="cubs-lz4-", dir=args.output_boot.parent) as tmp:
        temp = Path(tmp)
        raw_path = temp / "Image"
        compressed_path = temp / "Image.lz4_legacy"
        roundtrip_path = temp / "Image.roundtrip"
        raw_path.write_bytes(image)
        run_magiskboot(args.magiskboot, "compress=lz4_legacy", str(raw_path), str(compressed_path))
        compressed = compressed_path.read_bytes()
        run_magiskboot(args.magiskboot, "decompress", str(compressed_path), str(roundtrip_path))
        roundtrip = roundtrip_path.read_bytes()
        if roundtrip != image:
            fail("legacy-LZ4 decompression did not reproduce the source Image byte-for-byte")

    struct.pack_into("<I", header, 8, len(compressed))
    boot = bytearray(header)
    boot.extend(compressed)
    boot.extend(bytes((-len(boot)) % PAGE_SIZE))
    if len(boot) != PAGE_SIZE + ((len(compressed) + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1)):
        fail("internal Android page-padding calculation mismatch")

    # The boot header must remain identical to the supplied template except
    # for kernel_size, which describes the newly compressed stream.
    expected_header = bytearray(template[:PAGE_SIZE])
    struct.pack_into("<I", expected_header, 8, len(compressed))
    if boot[:PAGE_SIZE] != expected_header:
        fail("unexpected boot header change outside kernel_size")
    if boot[PAGE_SIZE:PAGE_SIZE + len(compressed)] != compressed:
        fail("compressed kernel bytes are not at the Android v4 kernel offset")
    if any(boot[PAGE_SIZE + len(compressed):]):
        fail("nonzero kernel page padding")

    args.output_kernel.write_bytes(compressed)
    args.output_boot.write_bytes(boot)
    print(f"ARM64 Image bytes={len(image)} sha256={sha256(image)}")
    print(f"legacy-LZ4 bytes={len(compressed)} sha256={sha256(compressed)} roundtrip=PASS")
    print(f"boot v4 bytes={len(boot)} kernel_size={len(compressed)} sha256={sha256(boot)}")
    print(f"header template preserved except kernel_size: PASS ({args.template})")


if __name__ == "__main__":
    main()
