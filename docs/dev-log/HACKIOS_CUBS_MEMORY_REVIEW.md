# HackiOS memory model against the CUBS live FDT and `/proc/iomem`

This is a host-side comparison of the raw FDT and `/proc/iomem` copied from Android (ADB root in a KernelSU context), with HackiOS `xnuloader/loader.c`. It is not a UEFI `GetMemoryMap` capture and must not be treated as proof that an address is safe to load.

## New live capture (2026-10-22)

The Pixel connected as `product:cubs`, and `adb shell id` returned `uid=0(root)` with `context=u:r:ksu:s0`. The raw live FDT and Linux memory map are saved under `../outputs/cubs-live-devicetree-2026-10-22-android-01/`:

- `live-fdt.dtb`: 714,804 bytes, SHA-256 `1fa6de836c11f1d6a0f6033169f0ff8cad872d461251cf20530477da01c179c7`. It identifies `google,malibu-cubs` / `google,malibu`, reports the six RAM banks below, has 54 direct `/reserved-memory` children and 44 fixed `reg` tuples, and has no FDT header memreserve entries. None of the fixed `/reserved-memory/reg` tuples overlaps the upper 10 GiB span.
- `proc-iomem.txt`: 420 lines, SHA-256 `d3d88efad2cde79d639adf8401f5b3c6af62bc151caaa43c8fca0fa2a3965dba`. Linux reports the upper span as one `System RAM` range, `0x880000000-0xb00000000`, with reserved subranges beginning at `0xabbf49000`. Subtracting the merged ranges labeled `reserved` leaves a largest current-Linux interval `0x880000000-0xabbf49000` (8.937 GiB). In particular, `[0x880000000,0xa00000000)` is a 6 GiB contiguous interval before those reported reservations.
- `runtime-cpu-memory.txt`: records CPUs `0-6`, `MemTotal=11,926,628 kB`, `MemAvailable=6,530,388 kB`, and CMA `774,144 kB` with `CmaFree=0`. The kernel does not expose `ID_AA64MMFR0_EL1` through the queried sysfs path, so Tensor G6 `PARange` remains unknown.
- The Mac's 64 MiB `vendor_kernel_boot_a.img` was copied and hash-checked (`d6cc6d0b297fe612d65dbba3b611fd0f958fbd5cbd945d35a416c9f608afa052`). Its concatenated DTB area contains two `google,mbu` trees; each has only a 256 MiB memory node at `0x80000000`. They are not the live `google,malibu-cubs` FDT and do not explain its 12 GiB map.

These are Android runtime observations. Linux's `/proc/iomem` reservations and RAM ownership do not establish that the same interval is `EfiConventionalMemory` before boot, and the FDT captured after Android boot carries Android runtime properties. Do not use the 6 GiB interval as a loader allocation until a CUBS UEFI diagnostic logs the post-start `GetMemoryMap`.

## CUBS RAM reported by Android

The captured tree describes six 2 GiB memory banks:

- `0x80000000-0x100000000` (2 GiB)
- `0x880000000-0x900000000`
- `0x900000000-0x980000000`
- `0x980000000-0xa00000000`
- `0xa00000000-0xa80000000`
- `0xa80000000-0xb00000000`

The five upper banks are adjacent and together describe one 10 GiB physical span from `0x880000000` through `0xb00000000`. The raw FDT confirms the earlier DTFS inventory: its 54 direct `/reserved-memory` children have 44 fixed `reg` tuples, all in the low bank. Dynamic reserved-memory pools and boot-firmware reservations are still possible; Android's current `/proc/iomem` also reports runtime reserved regions in the upper span.

After subtracting active fixed `/reserved-memory/reg` entries from the low bank, the DTFS exposes a gap `0x97400000-0xa0000000` containing `0x9fd00000-0x9ff00000`, and another gap `0xef000000-0xf6fce000` containing `0xf0000000-0xf4000000`.

Those intervals mean HackiOS's Redwood defaults `FD_BASE=0x9fd00000`, `FD_SIZE=0x200000`, and `PAYLOAD_BASE=0xf0000000` pass this limited DTFS overlap check. They remain unapproved candidates: only the CUBS UEFI `GetMemoryMap` and boot-shim execution can establish whether the ranges are available at load time. Do not set them in a boot profile based on this report alone.

## HackiOS loader requirements

The referenced `xnuloader/loader.c` defines `MAX_MEM_SIZE=0x180000000` (6 GiB), picks the largest `EfiConventionalMemory` descriptor, aligns the selected start/end to 32 MiB, excludes its fixed 64 MiB payload range, then claims one contiguous window with `AllocateAddress`. The XNU `boot_args.memSize` is set to that window size.

For its second Fastboot RAM download, the loader reserves `0x08000000` (128 MiB) from the start of that window and `0x30000000` (768 MiB) for the kernel. It therefore rejects a window of 896 MiB or less. A 2 GiB window would leave about 1.125 GiB for the resident root image; a 6 GiB window would leave about 5.125 GiB.

The CUBS DTFS upper span is large enough for this design if CUBS UEFI exposes at least 6 GiB of it as one conventional-memory descriptor. The exact HackiOS XNU source's address masks can represent the high range, but this remains a promising compatibility result, not a bootability result. The actual UEFI map may split or reserve the region, and the Tensor G6 CPU's physical-address range still needs runtime confirmation.

The completed generic iOS 16.5 `system.apfs` image is 2,492,203,008 bytes (about 2.32 GiB); `root.apfs` is 4 MiB. Those two images fit within the loader's estimated 5.125 GiB RAM-disk budget after kernel and upload reservations, if the required contiguous 6 GiB UEFI memory window exists. This resolves image size as a plausible rather than immediate blocker; it does not validate the CUBS memory map or any boot package.

## XNU physical-address and bootstrap-table check

The exact Apple XNU base used by HackiOS, `xnu-8796.121.2`, has a 48-bit physical-page output mask in `osfmk/arm64/proc_reg.h`. Its `TCR_IPS_VALUE` selects a 40-bit physical address size by default, or 42 bits when `__ARM_42BIT_PA_SPACE__` is set. The captured CUBS high bank starts at `0x880000000` (34 GiB) and ends at `0xb00000000` (44 GiB), so that span is within even the default 40-bit translation range. This removes an apparent XNU address-mask obstacle; it does not establish the Tensor G6 CPU's `PARange` value or that the bootloader supplies usable RAM there.

HackiOS's XNU patch reserves 20 hardware pages for bootstrap translation tables and says this covers an 8 GiB mapping; its loader deliberately caps the selected contiguous window at 6 GiB. Keep that cap for the CUBS first entry. Do not pass the full 10 GiB bank or combine the separated 2 GiB low bank with the upper bank as one `memSize` range.

## Next evidence to collect

1. Trace how the boot chain supplies the final `google,malibu-cubs` FDT and the 12 GiB memory map; the `vendor_kernel_boot_a.img` trees and the v4 `vendor_boot_a/b` backups (`dtb_size=0`) do not provide that final tree.
2. Build a CUBS UEFI diagnostic that reports GOP geometry and the post-start `GetMemoryMap`; confirm the shim/payload ranges and a contiguous conventional window before selecting fixed addresses. Obtain `ID_AA64MMFR0_EL1.PARange` from a diagnostic that can read it at an appropriate exception level; the Android sysfs export is absent.
3. Keep all tests RAM-only. Preserve both Android slots and all partitions.

## Cross-check from a third live capture (2026-10-22)

After USB debugging was enabled and the Mac was authorized, a fresh read-only capture was saved under `../outputs/cubs-live-devicetree-2026-10-22-android-03/`. Its raw FDT is 714,804 bytes (SHA-256 `b5e763f7d9caaed045fcde1de048498a9c51d19611c382e7114d6fa47daeb6bf`); `/proc/iomem` is 23,590 bytes (SHA-256 `d12336ef8d1879cf679e3b8fecff97e2ee608330d3465bee477b147fae90e228`). The latter matches capture 02 byte-for-byte.

Normalized `dtc` output compared with capture 01 has only two property changes: the AVF Secretkeeper public key and UFS PHY calibration data. The six 2 GiB RAM banks, fixed reserved-memory nodes, GICv3, PSCI, and board topology are stable. Treat the changed values as per-device/runtime inputs; do not bake them into generic UEFI/XNU configuration. The fresh FDT still describes Android after boot and `/proc/iomem` still is not the UEFI memory map, so this cross-check does not approve any payload address.
