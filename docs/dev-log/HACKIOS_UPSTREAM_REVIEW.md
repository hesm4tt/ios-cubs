# HackiOS upstream review

Reviewed 2026-10-22. The user pointed to the newly public `oosexgang/hackios-xnu-kernel` and `oosexgang/hackios-xnu-userland` repositories as a possible baseline for the Pixel 11 CUBS port.

## Finding

This is a much closer starting point than the earlier iPadOS-oriented `UniXNU-cubs` experiment. HackiOS runs iOS 16.5 userland with XNU `8796.121.2` on an Android phone, through an EFI loader and a UEFI image started with `fastboot boot`; its documented phone flow is RAM-only. The upstream phone is a Qualcomm POCO X5 Pro (Snapdragon 778G), though, and its own porting guide calls another Qualcomm phone the realistic next target. Pixel 11 is Tensor, so this gives us the architecture and reusable userland/kernel work, not a ready-to-boot Pixel image.

The upstream guide's first port milestone is a device profile derived from the phone DTB, then a device UEFI port, loader platform definition, and kernel hardware support. It identifies framebuffer + CPU as the minimal boot path before touchscreen, GPU, Wi-Fi, sound, and other drivers. The current generic `UniXNU-cubs` output is an iPadOS 17.7.11 / `DEVELOPMENT_ARM64_BCM2837` build and is not a Pixel-targeted kernel.

## Source checkout

Cloned kernel repository to the Mac at `~/unixnu-pixel11/hackios-upstream`, preserving all existing checkouts. Reviewed upstream revision `8e61187098f2c26c5daee8f9f72b6416aa64b9ab` (2026-10-22). The companion userland was set up (commit `906425b`); its iOS 16.5 input extraction completed. The generic userland image build produced `root.apfs` (4 MiB), `system.apfs` (2,492,203,008 bytes), and `rc.jobs.apfs` (754 bytes). Their SHA-256 values and the pending independent APFS validation are recorded in `PORT_STATUS.md`. These are generic iOS inputs, not a CUBS boot image. The kernel repository is Apple Public Source License 2.0; userland's own code is MIT. Third-party and Apple IPSW contents retain their separate licenses; the repositories do not include Apple's iOS files.

## Existing device input

Copied the stock CUBS `vendor_kernel_boot_a.img` from the Mac to `outputs/pixel11-cubs-stock-kernel-boot-2026-10-22/vendor_kernel_boot_a.img` (64 MiB; SHA-256 `d6cc6d0b297fe612d65dbba3b611fd0f958fbd5cbd945d35a416c9f608afa052`). A raw scan found plausible FDT headers at offsets 5,455,872 (declared total size 534,937) and 5,990,809 (declared total size 538,675). They have not yet been validated against the vendor_boot v4 layout; extract via the Android `unpack_bootimg.py` parser or validate both FDT headers before using either as a port input.

## Next steps

1. On the next reliable Mac connection, run the repository's independent APFS checker on the completed generic images and preserve its output.
2. Obtain the raw live FDT and `/proc/iomem` from CUBS Android when the device is available. The existing live DTFS inventory reports six 2-GiB RAM banks, but it is not the raw FDT or its reservation map.
3. Use `common/new-device.sh cubs <validated-dtb>` to create a draft HackiOS profile, then resolve Tensor-specific memory map, framebuffer, peripheral window, UEFI firmware, and driver support. Do not copy Qualcomm values into the Tensor profile.
4. Keep builds and image artifacts RAM-boot only. Do not flash or erase Android partitions. Verify every packed image before any `fastboot boot` experiment.

The Pixel was not connected to fastboot in the last host check, and no HackiOS image has been built or boot-tested for CUBS yet.


## Validated CUBS device trees

Using the copied vendor boot image, the Android v4 header declares a 1,073,612-byte DTB region at computed offset 5,455,872. It contains two structurally valid, contiguous FDT blobs (534,937 and 538,675 bytes); their total sizes exactly cover the declared DTB region. Both identify the root compatible as `google,mbu`, seven CPU nodes with MPIDRs 0 through 0x600 in steps of 0x100, GICv3 distributor at 0x9228000 and redistributor at 0x92a8000, and PSCI via SMC. The chosen bootargs use `earlycon=uart8250,mmio32,0x3bdd6000` and `console=ttyS0,12500000n8`; the serial0 alias points to that UART and has no status property. Serial1 at 0xda24000 is marked disabled in these vendor FDTs. This differs from the earlier live Android DTFS inventory, so the active-console source must be reconciled. The FDT memory node reports only 256 MiB at 0x80000000; do not treat that as the device's full RAM map until checked against the bootloader and live memory map.

Both extracted DTBs and their inventory are saved alongside the source image and were structurally validated. DTBO index 10 (board id `0x80606`, revision `0x10000`) matches CUBS MP and applies to the base tree; the merged tree still reports only 256 MiB. A separate live Android DTFS inventory reports six 2-GiB banks (12 GiB), so neither base nor merged vendor FDT is safe as the final memory map. The raw live FDT and `/proc/iomem` remain the useful evidence called for by the user's guide.

## Relevance of the sweet porting guide

The user's pasted `hackiosx.dev/porting` page documents the separate `ios-sweet` Snapdragon/Redmi Note 10 Pro shim port. Its hardware inventory and incremental bring-up method are useful. Its hard-coded Qualcomm PSHOLD/IMEM/SPMI/RPMh/GENI values, Goodix driver, framebuffer dimensions, and `userdata` image-install step do not transfer to CUBS. The more directly applicable guide for the repositories at `oosexgang/hackios-xnu-kernel` is its own `docs/PORTING.md`: it uses Mu-Silicium UEFI plus `xnuloader`, calls Qualcomm the realistic next target, and starts from `common/new-device.sh`. CUBS is Tensor G6 and still needs a UEFI package and platform drivers.

## EDK2 Tensor reference audit (2026-10-23)

The local `references/edk2-tensor` checkout (commit `9b11e80`, from [TAOcroatia/edk2-tensor](https://github.com/TAOcroatia/edk2-tensor)) is a useful firmware reference for the boot-image stage. It contains Pixel 6 Pro (`raven`) and Pixel 6a (`bluejay`) targets on first-generation Tensor. Its own README calls the memory map experimental and says it was derived from `/proc/iomem`. It is not a Pixel 11/Tensor G6 port.

The checked-in platform map hard-codes GICD/GICR at `0x10400000`/`0x10440000`, while CUBS's saved live Android FDT reports `0x09228000`/`0x092A8000`. The EDK2 config also uses a G1-era fixed memory map and framebuffer setup. Those values must not be carried into a CUBS build. The repository's EDK2 submodules are not initialized in this local reference, and its Android boot shim is separate from HackiOS's Mu-Silicium/XNULoader flow, so it is a design reference rather than a ready firmware image.

The reference `raven-build-and-run.sh` enables ramdump modes with `fastboot oem ramdump` before booting. That security-changing debug setup is not needed for the CUBS port and was not run.
