# CUBS boot-path findings from iOS Bluejay

Checked 2026-10-22 against `dristotle/ios-bluejay`, branch `bluejay-port`,
tree commit `770236a7ab8ea14101304e50b06d6fa54c49d52c`.

## What transfers

The useful result is a tested direct boot path for an experimental iOS/XNU
port on a Pixel Tensor device. Bluejay's documented sequence is an unlocked
Pixel bootloader, temporary `fastboot boot` of an Android boot v4 image, a
small ARM64 shim, an embedded XNU payload, and then the iOS HFSX root in
`userdata`. That route does not require a CUBS UEFI firmware port as a
prerequisite.

The source confirms the important packaging and loader details:

- `shim/build-bluejay.sh` packages the shim as an Android boot v4 kernel with
  legacy-LZ4 compression. It creates the image with the installed vendor
  boot data still available to the bootloader.
- `shim/shim.ld` places the XNU payload inside the decompressed shim image;
  `shim/loader.c` locates it through linker symbols rather than assuming
  `/chosen/linux,initrd-start` identifies the generic ramdisk.
- `tools/mkpayload.py` resolves XNU Mach-O chained fixups on the host, then
  records its flat segments, Apple Device Tree, boot arguments and command
  line. The shim copies the segments, stages the boot metadata and jumps to
  XNU.
- `shim/start.S` handles an EL2 entry and transitions to EL1. This matters
  because CUBS's diagnostic entry EL has not yet been observed.
- The project documents a lock-screen boot and touchscreen input on Pixel 6a.
  Its README also lists Wi-Fi, cellular, audio, camera, sensors, SEP and GPU
  acceleration as unavailable.

## What must be CUBS-specific

Bluejay targets GS101 and hard-codes Bluejay's GIC, timer, UFS, framebuffer,
RAM bank, watchdog and touch configuration. Those values cannot be copied to
Pixel 11. The CUBS runtime capture instead reports seven CPU MPIDRs, GICD
`0x09228000`, GICR `0x092a8000`, UFS `0x3c2d0000`, six RAM banks, and a
1080x2424 panel. The captured Android FDT does not supply a verified display
framebuffer address, and it is not yet proven to be the FDT passed by
Fastboot.

The Bluejay shim's ARM64 Image header uses `text_offset=0x80000`; the
decompressed Pixel 11 stock kernel says `text_offset=0`. Keep the CUBS value
at zero. This is one concrete example where the loader source transfers but
its image constants do not.

The Bluejay loader also allocates boot metadata and XNU memory using the
device's verified memory range. For CUBS, `/proc/iomem` and the Android runtime
FDT are evidence about Android's current layout, not a validated Fastboot
handoff map. Keep the CUBS loader profile fail-closed until its own payload
range and all required boot metadata ranges are checked against the actual
handoff.

## Pixel 11 image-format comparison

The local stock `boot_a.img` was inspected with MagiskBoot. It is Android boot
v4 with a 4 KiB page and legacy-LZ4 kernel section. The decompressed stock
kernel's ARM64 Image header reports `text_offset=0`, `flags=0xa`, and the
`ARM\x64` magic. Those fields match the current CUBS diagnostic Image; the
diagnostic differs in kernel compression. This supports building a
stock-format LZ4 diagnostic package, but does not prove that its entry point
or FDT handoff is correct.

`tools/pack_cubs_lz4_bootv4.py` creates that package from the already-built
CUBS diagnostic Image and its verified v4 header template. It round-trips the
legacy-LZ4 data and checks that the template header is unchanged except for
the compressed kernel size. The artifact is host-validated only; it has not
been booted. The 2026-10-22 host build is documented in
`outputs/cubs-diag-stock-lz4-v4-2026-10-22/BUILD_NOTES.md`; its boot-image
SHA-256 is `efe095f802c7168938919207cff27d792d6399689af29275ee8c363812ffd290`.

## Next engineering sequence

1. Get a visible or captured entry signal from CUBS Fastboot. The current
   diagnostic UART address is only verified in Android's live FDT; neither
   UART routing nor the Fastboot FDT is confirmed.
2. Port the generic Bluejay shim/payload design to a separate CUBS profile:
   observed EL, CUBS CPU/GIC/timer/PSCI facts, and a verified safe memory map.
   Keep framebuffer fields absent until its address is verified.
3. Add a CUBS machine config and platform/timer/UFS support to the iOS 16
   XNU baseline. Do not enable the full CUBS CPU set until one-core boot and
   timer behavior are demonstrated.
4. Build the shim and XNU, verify the payload ranges, Mach-O fixups, ADT,
   boot arguments, LZ4 round-trip, Android v4 layout, and artifact hashes.
   Only then attempt a temporary `fastboot boot`; keep Android partitions
   unchanged until the XNU and userspace stages are reached.

The Bluejay source is used as a design reference. Its board-specific code and
artifacts were not copied into the CUBS tree.

## 2026-10-23 CUBS packaging probe

Rebuilt the current CUBS UART/FDT diagnostic with Bluejay's boot-image shape: legacy-LZ4 kernel, Android boot v4, `console=null`, and an empty gzip/newc ramdisk. The byte-level verifier and Mac LZ4 round-trip passed. The artifact is in `outputs/cubs-diag-bluejay-shape-2026-10-23/`; its boot image SHA-256 is `57601940ac43eba1ee39808c690ddf176db96afabc301271514032185d857d14`.

A RAM-only `fastboot boot` returned OKAY, but Fastboot stayed responsive for 12 seconds and the user reported the screen still showed Fastboot Mode. No partition writes occurred. This does not establish shim execution. The Android runtime FDT enables UART at `0xda24000`; the extracted static DTB from `vendor_kernel_boot_a.img` instead uses `0x3bdd6000` for `serial0` and marks `0xda24000` disabled. Capture/identify the actual Fastboot handoff DTB and entry EL before proceeding with a CUBS loader payload.

### Bluejay entry-path source comparison (2026-10-23)

- Bluejay's `shim/start.S` assumes the bootloader enters at EL1 or EL2. On EL2 it explicitly grants EL1 timer access, clears `CNTVOFF_EL2`, sets `HCR_EL2.RW`, initializes `SCTLR_EL1`, selects masked EL1h in `SPSR_EL2`, and `eret`s to its EL1 setup. CUBS's current diagnostic records the entry EL and can run its probe at EL2, but it does not drop to EL1. A CUBS XNU payload must add and validate that transition before jumping into XNU.
- Bluejay sets `text_offset=0x80000` under `SHIM_BLUEJAY`; CUBS's decompressed stock ARM64 Image reports `text_offset=0`. Keep the device-specific CUBS value rather than copying Bluejay's load offset.
- Bluejay's linker page-aligns the final image and embedded payload; CUBS's current diagnostic linker ends at the stack boundary (the built Image is 22,656 bytes / `0x5880`). This is not shown to cause the current Fastboot result, but the CUBS XNU shim should page-align payload and image bounds before embedding and jumping into XNU.
- Bluejay's build uses Android boot v4, legacy-LZ4 compression, a small empty gzip/newc ramdisk, `console=null`, and OS metadata for 16.0.0 / 2026-10; its script states that the installed `vendor_boot` supplies the FDT. The CUBS Bluejay-shape package header matches those OS metadata values (`0x200001aa`), but the latest test still showed Fastboot and supplied no execution marker.
- Bluejay documents macOS 14 with Xcode 15.0.1 for its XNU workflow and reports Xcode 16 `iig` ABI incompatibility. The Mac's Xcode 27 beta is not a validated substitute; the kernel build/toolchain remains a separate blocker.

### EL2-to-EL1 reset probe (2026-10-23)

Built and host-verified an isolated CUBS probe that adopts Bluejay's EL2-to-EL1 transition, page-aligns the Image, and selects a delay based on the original entry EL before requesting PSCI `SYSTEM_RESET`. `fastboot boot` accepted it. The Mac observed Fastboot USB disappear and return; read-only queries then reported `product=cubs`, `is-userspace=no`. This is consistent with execution or a firmware reset, but does not prove the shim reached EL1 or identify the original EL. No partition was flashed, erased, or written. See `outputs/cubs-bluejay-el1-reset-probe-2026-10-23/BUILD_NOTES.md` and the isolated source under `cubs-shim-staging/bluejay-el1-prototype/`.

## Bluejay is a Tensor reference (2026-10-23)

The public [iOS Bluejay project](https://github.com/dristotle/ios-bluejay) is a
major proof of concept: its README reports iOS 16.7.16 reaching the lock screen
on a Pixel 6a with touchscreen input. It uses the iPhone X userland and XNU
8796, an Android v4 `fastboot boot` image with legacy LZ4, and a shim that
hands off to XNU. Its reported hardware support is specific to GS101: four
A55 cores, 16 KiB kernel pages, GS101 UFS, Pixel 6a framebuffer, and FTM5
touch. Wi-Fi, GPU acceleration, audio, cameras, and cellular are listed as
unsupported. Treat the report as the project's claim; it has not been
independently reproduced in this CUBS worktree.

The reusable part is the loader design and proven build/package structure. Do
not transplant Bluejay's board addresses, memory map, CPU topology, UFS, display,
or touch routines into CUBS. The Pixel 11 live Android FDT identifies a
different board (`google,malibu-cubs`), including a `google,ufshc` controller,
a Verisilicon DC9x00 display controller, and a Google DCSDB 1080x2424 panel.
These Android runtime properties do not by themselves establish safe Fastboot
handoff memory, display, or storage initialization.

Other public Pixel 11 kernel sources are not equivalent to an iOS port. The
published `kernel/devices/google/p11` main branch was empty in the checked
revision; its populated 5.15 branch is Qualcomm SW5100 and carries Qualcomm
display/touch descriptions. The [Espada Kernel](https://github.com/atrejokm301/espada-kernel)
README claims Pixel 11 family support and testing on `grizzly`, but its
reviewed tracked tree had no CUBS/`malibu`/DC9x00 board source or XNU drivers.
These are useful Linux build references only, not CUBS XNU support.

### CUBS entry probes following the Bluejay comparison

Two separately built Android v4 + legacy-LZ4 packages reused Bluejay's EL2 to
EL1 entry sequence and page-aligned image. Both used `fastboot boot` only; no
partition was flashed, erased, or written.

- The timed reset probe waited for 5 or 10 seconds using the architected counter
  before requesting PSCI reset. USB re-enumerated about 1.85 seconds after the
  second disconnect, so the requested delay was not observed. Details and hashes
  are in `outputs/cubs-bluejay-el1-timed-reset-probe-2026-10-23/BUILD_NOTES.md`.
- The hold probe parks forever in the normal C entry path and requests PSCI
  reset only from the exception handler. USB re-enumerated about 1.87 seconds
  after the second disconnect and remained in Fastboot for the 40-second
  observation window. That argues against reaching the normal hold loop; an
  exception, firmware reset, or earlier boot rejection remain possible. See
  `outputs/cubs-bluejay-el1-hold-probe-2026-10-23/BUILD_NOTES.md`.

These runs narrowed the earlier failures to handoff or early shim execution,
but provided no positive EL1, UART, framebuffer, or XNU-entry marker. A later
stock-header PSCI system-off control changed that assessment: see the result
below. The next useful work is still to inspect the actual Fastboot handoff
(entry EL and x0 FDT) or establish a verified output channel. Do not use guessed
CUBS MMIO to create a display marker. The current XNU candidate still lacks a
runtime-qualified CUBS platform and UFS path, so the full iOS image is not yet
bootable.

### Android readout after the probes (2026-10-23)

After an earlier safe `fastboot reboot`, the Pixel returned to stock Android
and root ADB was online. Android's kernel log reported the physical
architected timer at `999.99MHz`; `/proc/timer_list` gave
`mult=16777190`, `shift=24`. `/sys/fs/pstore` was empty and the earlier
`ro.boot.bootreason` was `reboot`. This makes a slow Android counter an unlikely
explanation for the earlier timed probe's short USB cycle, but does not reveal
the exact `CNTFRQ_EL0` value read by the shim at handoff. The Mac's copy of
stock `boot_a.img` matches the local saved image hash and remains available as
a known-good temporary boot control.

### Stock CUBS watchdog stop probe (2026-10-23)

Read-only comparison of the live Android FDT and stock `vendor_kernel_boot_a`
DTB confirms two `google,wdt` nodes at `0x200c4000` and `0x200c5000`. Their
matching stock `google_wdt.ko` was extracted and disassembled. It uses a
38.4 MHz clock and stops a watchdog by writing the unlock key to `+0x10`,
programming `timeout_sec * clock_rate` at `+0x0c`, clearing bit 0 at control
register `+0x08`, and relocking at `+0x10`.

An Android boot v4 / legacy-LZ4 probe mirrors that sequence for both
watchdogs, waits five seconds using the architected counter, then requests
PSCI reset. It was temporarily booted; Fastboot USB disappeared 0.763 seconds
after launch and returned at 2.761 seconds while the screen remained in
Fastboot. The timer interval was not observable. The local build artifact is
`outputs/cubs-google-wdt-stop-probe-2026-10-23/cubs-google-wdt-stop-probe.img`
(SHA-256 `a912fbb938794492aa268c7efe7fbd8492fd350b1676d00b64e7c3749fa969c2`).
It touches only the two watchdog register blocks during a RAM boot; no Android
partition was written. See the artifact's `BUILD_NOTES.md` for recovery
details.

### Stock-header PSCI system-off control (2026-10-23)

The small generated-wrapper image returned to Fastboot too quickly to establish
that its payload executed. A second image was built from the verified stock
`boot_a.img`: its 4 KiB Android v4 header and all stock bytes outside the kernel
span were preserved, while only the kernel-size field and kernel data span
changed. The replacement kernel was the same 4 KiB legacy-LZ4 ARM64 image that
sets a vector table, calls PSCI `SYSTEM_OFF` (`0x84000008`), and waits if the
call returns. Fastboot accepted the 64 MiB image; the watcher saw USB disappear
at 12.867 seconds after launch and remain absent through its 20-second window.
The user saw a black or powered-off screen, then powered the phone on. It
showed the unlocked-bootloader warning and booted stock Android. Read-only ADB
then reported `ro.boot.bootreason=shutdown`; `/sys/fs/pstore` was empty.

Together, the screen and bootreason are strong evidence that this stock-header
RAM image reached a PSCI power-off path. They do not identify the entry EL,
verify the x0 FDT, or establish a general shim/XNU handoff. The roughly
11-second interval between `fastboot boot` returning and USB disappearing is
unexplained. Future probes should use the preserved stock image format as the
base. No partition was written.

### FDT header handoff probe (2026-10-23)

A second stock-header probe checked the ARM64 handoff pointer in `x0` before
selecting its PSCI result. It required 8-byte alignment, the FDT magic, and a
big-endian `totalsize` from 40 bytes to 16 MiB. A valid header called
`SYSTEM_OFF`; an invalid header or data abort called `SYSTEM_RESET` through
the current-EL exception vector table. The image read no MMIO and wrote no
partition.

Fastboot accepted the 64 MiB stock-based RAM image. The Mac watcher observed
Fastboot disappear 12.242 seconds after launch and not return during its
45-second window. The user saw a black or powered-off screen, then powered the
Pixel on. Stock Android started, and read-only ADB reported
`ro.boot.bootreason=shutdown`; `/sys/fs/pstore` was empty. This strongly
supports that the probe's FDT-success path ran, establishing a well-formed FDT
header at the ARM64 `x0` pointer. It does not validate the rest of the FDT or
establish the exact FDT contents. The exact memory map and board properties
passed by Fastboot remain unknown. See
`outputs/cubs-fdt-system-off-probe-2026-10-23/BUILD_NOTES.md` and the
source under `cubs-shim-staging/fdt-system-off-probe/`.

### Fastboot entry EL probe (2026-10-23)

A separate 4 KiB stock-header probe read `CurrentEL` and made no FDT or MMIO
access. It called `SYSTEM_OFF` at EL2 and `SYSTEM_RESET` at EL1 or from an
exception vector. Fastboot accepted the RAM image; USB disappeared 12.307
seconds after launch and did not return during a 45-second observation. The
user saw black/off. After a physical power-on, stock Android started and
read-only ADB reported `ro.boot.bootreason=shutdown`; pstore was empty. This
strongly indicates the payload took the EL2 branch, so CUBS Fastboot enters at
EL2. The reset outcome would normally return to Fastboot. The probe did not
transition to EL1. See
`outputs/cubs-entry-el-probe-2026-10-23/BUILD_NOTES.md` and
`cubs-shim-staging/fdt-system-off-probe/entry_el_probe.S`.

### EL2-to-EL1 transition and FDT header at EL1 (2026-10-23)

The next stock-header probe required EL2 entry, enabled EL1 timer access,
cleared `CNTVOFF_EL2`, set `HCR_EL2.RW`, and used `eret` to enter EL1h. At EL1
it checked `CurrentEL`, rechecked the aligned `x0` FDT header, and requested
`SYSTEM_OFF`; invalid data and exceptions requested `SYSTEM_RESET`. The user
reported black/off. After a physical power-on, read-only ADB reported
`ro.boot.bootreason=shutdown`, with an empty pstore. Together with the prior
EL2-only probe, this supports a successful EL2-to-EL1 transition and valid
FDT header access at EL1. It does not validate the complete FDT or establish
XNU-ready CPU state. See
`outputs/cubs-el2-to-el1-fdt-probe-2026-10-23/BUILD_NOTES.md` and
`cubs-shim-staging/fdt-system-off-probe/el2_to_el1_fdt_probe.S`.

The next test invokes the bounded `fdt_validate` parser at EL1. A complete
valid FDT should follow the `SYSTEM_OFF` path; invalid data or an exception
should return through `SYSTEM_RESET`. It has no MMIO or partition writes. Its
source and build script are under `cubs-shim-staging/fdt-full-probe/`.

### Full FDT validation probe (2026-10-23)

The probe called the bounded C `fdt_validate` routine at EL1 with an 8 MiB
maximum span. It requests `SYSTEM_OFF` only when the complete header, reserve
map, strings and structure validate; invalid data or an exception requests
`SYSTEM_RESET`. It performs no MMIO. All nine host vectors passed, and the same
validator accepted a fresh 714,804-byte Android FDT (version 17). The ARM64
Image is 36 KiB; the build found no runtime relocations or undefined symbols,
verified its legacy-LZ4 round trip, and preserved the stock Android boot v4
header in the 64 MiB RAM image.

Fastboot accepted the stock-header image. USB disappeared 12.359 seconds after
launch and stayed absent through the 45-second observation. The user confirmed
the Pixel is black/off. After power-on, read-only ADB confirmed
`ro.boot.bootreason=shutdown` and an empty pstore. Together, these observations
strongly support that the complete Fastboot FDT passed validation at EL1 and
the probe reached its PSCI `SYSTEM_OFF` success path. See
`outputs/cubs-full-fdt-probe-2026-10-23/BUILD_NOTES.md`, its run log, and
`cubs-shim-staging/fdt-full-probe/`.

### Direct XNU handoff checkpoints (2026-10-23)

The first direct XNU RAM image used the corrected ARM64 dual-entry header and
completed its 45-second Fastboot observation without a visible USB transition.
After Android returned, read-only ADB reported
`ro.boot.bootreason=watchdog,apc,early`. The saved bootloader console log
records `RST_STAT: Fatal Error HW`, `APC Watchdog Early`, and an APC watchdog
expiry about 74 seconds into that reset history. This is consistent with an
early XNU stall, but does not locate the stalled instruction.

The built `mach.development.bcm2837` kernel contains the HackiOS `XNULDRST`
slot and early startup checkpoints 1–5. The direct CUBS shim had not populated
that slot, so an early kernel exception could spin until the AP watchdog. The
shim now patches the slot to a no-stack assembly callback: a checkpoint return
requests PSCI `SYSTEM_OFF`, while an early exception requests PSCI
`SYSTEM_RESET`. This changes only the temporary RAM image.

The checkpoint-1 image passed the FDT/window, ARM64 Image, LZ4 round-trip, and
stock boot-v4 header checks. `fastboot boot` accepted it. Fastboot USB
disappeared 12.466 seconds after launch and remained absent for the 45-second
observation; screen and post-boot reason confirmation are pending. That timing
is consistent with reaching XNU's first checkpoint and powering off, but is
not yet confirmed. Checkpoint variants 2–5 are also built and host-validated.
Image hashes and run logs are under
`outputs/cubs-xnu-bootstrap-2026-10-23/`.

This is evidence of kernel-entry progress only. The payload has no iOS root
image, CUBS display driver, or Tensor UFS driver, and the BCM2837 XNU build is
not a CUBS platform build. There is still no bootable iOS image. The Pixel's
Android partitions have not been flashed, erased, or written.
