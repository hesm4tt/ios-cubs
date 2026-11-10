# CUBS iOS/XNU development plan

Updated **2026-10-24**, America/New_York. This is the forward plan for the user's Pixel 11, Android/Fastboot product `cubs`, whose captured device tree identifies `google,malibu-cubs` / `google,malibu`. Project notes call the SoC Tensor G6. Hardware decisions must continue to use measured CUBS information.

The target is an experimental **iOS 16.5 phone boot**, using the HackiOS XNU 8796.121.2 and userland work, with a CUBS boot shim and platform implementation. The immediate BSD startup blocker was a boot-order deadlock: `mcache_init()` waited for a CPU count that the generic IOKit CPU driver publishes only later. A scoped `cpus=1` publication fix passes CP100, CP110, CP111, CP113, CP115 and CP116 on one kernel build. CP112 was RAM-booted; USB disappeared and the user saw black/off, but a later Fastboot-to-Android reboot replaced the boot-reason evidence, so the marker remains probable rather than confirmed. CP113 after `inittodr(0)` is confirmed. CP114, after `vfs_mountroot()` returns, was followed by `kernel_panic,early` and an APC watchdog record; the marker was not confirmed. The no-root payload may explain the stall, but that remains to be established. CP92 remains downstream and should wait until the root-mount path is understood. There is no working CUBS iOS interface yet.

This document supersedes the **next-step instructions** in `HANDOFF_2026-10-23.md`, the older UniXNU/iPadOS build notes, and older notes that make a UEFI port a mandatory prerequisite. Keep those documents as historical evidence. The detailed running log remains `PORT_STATUS.md`.

## 1. What counts as completion

Use separate milestones so an accepted Fastboot download or an Apple logo is not mistaken for a working port.

| Milestone | Required demonstration |
| --- | --- |
| Kernel startup | XNU reaches a named point, with evidence distinguishing the selected checkpoint from a panic or hang. Already achieved through CP91 on the preceding build. |
| Stable headless system | A CUBS kernel mounts a test root, completes `bsd_init()`, executes a diagnostic userspace process, and provides readable logs beyond the watchdog interval. |
| iOS userspace boot | The selected iOS 16.5 userspace reaches launchd and essential services on the phone, with their failures visible in logs. |
| First interactive iOS build | The phone reaches the iOS lock screen with a working display and usable input, remains responsive for at least five minutes, and can return to Android. This is the initial product goal. |
| Broader hardware support | Networking, sound, charging/power management, graphics acceleration and other features have individual acceptance criteria. A lock-screen boot does not establish these. |

Do not make a full Metal implementation, cellular service, cameras, or complete Apple hardware equivalence prerequisites for the first interactive boot. Track them as separate development projects.

## 2. Current evidence and immediate state

### Confirmed foundation

- The Mac sees serial `<adb-serial>` as `product:cubs`, model `Pixel_11`. Earlier read-only Fastboot checks reported `unlocked=yes` and `is-userspace=no`. The bootloader unlock question is settled by those observations.
- The working diagnostic wrapper preserves the saved **64 MiB stock Android boot-v4 image**, replacing the kernel span and kernel-size field. It uses legacy LZ4, the CUBS ARM64 Image settings, and an empty Android ramdisk. Smaller generated wrappers repeatedly failed to provide convincing entry evidence.
- Separate probes support EL2 entry, a successful EL2-to-EL1 transition, and complete structural validation of the incoming Fastboot FDT at EL1. These establish useful entry behavior; they do not establish ownership of every memory region described by that tree.
- CP10–CP21, plus CP31/32/42, were confirmed through the combined shutdown and post-boot evidence. CP14 was individually ambiguous but is covered by the later CP15 result.
- CP70, CP82, CP88 and CP91 were confirmed on the subsequent kernel. The last of these is immediately after `vm_set_restrictions()` and before `bsd_init()`. Early VM setup, kernel bootstrap, the first context switch, IOKit initialization and lockdown code have therefore executed on the phone.
- CP100, CP101, CP105, CP108 and CP109 were confirmed on a temporary kperf-workaround build. That workaround exposed the `mcache_init()` wait. The current build restores the ordinary `kperf_init_early()` wait and, only for `cpus=1` when `machine_info.max_cpus` is also 1, publishes that already parsed count before waiting. On this kernel, CP100, CP110, CP111, CP113, CP115 and CP116 returned cleanly. CP112 was accepted by Fastboot but its later boot reason was overwritten by a normal reboot. CP114 returned with `kernel_panic,early` and an APC watchdog record, so the `vfs_mountroot()` return checkpoint was not confirmed. CP92 after `bsd_init()` still watchdogs.
- Those markers establish that code returned at those points. They do not yet validate sustained timer interrupts, every RAM page, all scheduler behavior, display output, or storage.
- The active build still uses the generic `DEVELOPMENT_ARM64_BCM2837` configuration with a CUBS-generated Apple Device Tree and `cpus=1`. It is not a complete CUBS board port.
- The ADT omits display and UFS nodes, `boot_args.Video` is zero, and the current boot image contains no root filesystem.

### Latest `bsd_init()` investigation

CP92, immediately after `bsd_init()`, previously produced an automatic return to Android with `kernel_panic,early`. Its pstore contained bootloader crash-reset information, not XNU's console or a symbolized XNU panic.

The first CP100–CP114 results did not localize a `bsd_init()` failure: CP100 and later checkpoints were reached only after an earlier hang in `kperf_init_early()`. CP96, before `ml_wait_max_cpus()`, shut down cleanly; CP97, after it, produced the APC watchdog signature. A temporary workaround skipped that wait when no nonempty `kperf=` argument was supplied, allowing CP100–CP109 to run. It then exposed another wait in `mcache_init()`.

CP117, placed after `proc_uuid_policy_init()` and before `mcache_init()`, shut down cleanly. Source and linked disassembly showed `mcache_init()` immediately calls `ml_wait_max_cpus()`. On ARM, the generic `ml_set_max_cpus()` publisher is called by `GenericARMPE::start()` after CPU service enumeration through IOKit; that enumeration is reached later from `bsd_autoconf()`. This created a boot-order deadlock: `bsd_init()` waited for a value whose publisher starts after `bsd_init()`.

The diagnostic-specific fix restores the normal unconditional wait in `kperf_init_early()`. Before the wait, it publishes `machine_info.max_cpus` only when the boot arguments explicitly request `cpus=1` and the already parsed `machine_info.max_cpus` is exactly 1. Other CPU configurations retain XNU's normal IOKit publication path. The scoped XNU build completed with exit 0; stripped kernel SHA-256 is `0ca74af57f1255caf8e014a5c0368b861cad5ff5b64ff10da519b71c43cbb299`, and unstripped kernel SHA-256 is `04fd1aa9e593e4f40620b7b9b4e7a7522e7d82d96dee2ba556c9041d15a7ed0e`.

| Checkpoint | Intended stop point | Fixed-kperf build result |
| --- | --- | --- |
| CP100 | `bsd_init()` entry | Confirmed shutdown; empty pstore |
| CP101 | After `throttle_init()` | Confirmed shutdown; empty pstore |
| CP105 | After kernel credential setup | Confirmed shutdown; empty pstore |
| CP108 | After `IOKitInitializeTime()` | Confirmed shutdown; empty pstore |
| CP109 | After `vfsinit()` | Confirmed shutdown; empty pstore |
| CP110 | After `psem_cache_init()` | Earlier build watchdoged; current early-publication build confirmed shutdown, empty pstore |
| CP111 | After `sysctl_mib_init()` | Current early-publication build confirmed shutdown, empty pstore |
| CP112 | After `bsd_autoconf()` | Fastboot accepted image; USB disappeared at 12.528s and user saw black/off; subsequent Fastboot-to-Android reboot changed the boot reason to `reboot`, so checkpoint is probable but not independently confirmed |
| CP113 | After `inittodr(0)` | Confirmed: `ro.boot.bootreason=shutdown`, product `cubs`, empty pstore |
| CP114 | Immediately after `vfs_mountroot()` returns | Not confirmed: Android returned with `kernel_panic,early`; bootloader pstore records APC WDT `0xcbea`, GDMC reason `0xbab9`, and no CPU PC context; the no-root mount path is a likely but unproven cause |
| CP115 | After `knote_init()` | Earlier build watchdoged; current early-publication build confirmed shutdown, empty pstore |
| CP116 | After `mcache_init()` | Earlier build watchdoged; current early-publication build confirmed shutdown, empty pstore |
| CP117 | After `proc_uuid_policy_init()` | Confirmed shutdown on both earlier and current source builds |
| CP92 | After `bsd_init()` returns | Current early-publication build still produced `kernel_panic,early`; 54,600-byte bootloader log records APC watchdog, no CPU PC context |

The current early-publication image set uses the same XNU kernel and checked 64 MiB stock boot-v4 wrapper. CP100, CP110, CP111, CP113, CP115 and CP116 each returned through the shim's `SYSTEM_OFF` path; the observer captured `ro.boot.bootreason=shutdown`, product `cubs`, and empty pstore. CP92 returned with `kernel_panic,early`; its bootloader log SHA-256 is `fb3e2456d019b29a17e5e262e039d57d37e7f106ab6d59b3d036469038cef8cb`. CP112's package SHA-256 is `1589b3fdf961878ace318b912904f244bfd23de4ab4e94c25c96873f381264e4`; Fastboot accepted it, USB disappeared at 12.528s, and the user saw black/off. The later normal Fastboot reboot to Android reported `reboot` rather than preserving independent shutdown evidence, so CP112 is probable but unconfirmed. CP113's package SHA-256 is `70503b5d8c2ed271a7af463ba96fdcd5f1db109c4260994422330b48f34137c0`; the observer captured `shutdown`, product `cubs`, and empty pstore, confirming return from `inittodr(0)`. CP114's package SHA-256 is `8f177d6ed41b9f23b2e107aa631c6930f46b0844d1389b876eafd2a59d16b38d`; Fastboot accepted it and USB disappeared at 10.100s, then Android returned with `kernel_panic,early`. Its 54,834-byte bootloader log SHA-256 is `b6edf26eb663e9e733f2349db844345f0c95c2334f2aa40ae802707aea0893b3`; it reports `RST_STAT=0x3`, GDMC reason `0xbab9`, APC WDT subreason `0xcbea`, and no CPU PC context. This is consistent with a stall before `vfs_mountroot()` returns, but does not identify the exact code. CP114 would only mark a return; it does not prove a successful mount. USB timing and screen state are supporting evidence; post-boot reason and pstore remain the strongest confirmation.

The build command `bash xnu-build.sh build` after the kperf and CP115 source changes completed with exit code 0. It linked and stripped the kernel and emitted no export/import audit errors. The earlier `./xnu-build.sh -j8 -k` run did return nonzero on those checks; preserve that historical result, and keep the scoped `build` target as the reproducible diagnostic build until the broader export/install workflow is independently understood.

### Existing userland and hardware inputs

- Generic iOS 16.5 `root.apfs` is 4 MiB; `system.apfs` is **2,492,203,008 bytes**; `rc.jobs.apfs` is 754 bytes. Local and Mac hashes matched when copied.
- The HackiOS Python reader and the separate XNU C APFS reader traversed both images: 77 root entries and 62,356 system entries. `apfsck` was unavailable. Host traversal does not establish write safety or a successful on-device root mount.
- Android captures show seven CPU nodes, GICD `0x09228000`, GICR `0x092a8000`, PSCI through SMC, and an Android architected timer report of 999.99 MHz. The generated ADT currently uses `999990000` Hz.
- The captured RAM map has one low 2 GiB bank and an upper contiguous 10 GiB span. The diagnostic currently gives XNU `[0x880000000, 0xa00000000)`, a 6 GiB candidate range. Early VM startup through CP91 is encouraging; it does not prove unrestricted ownership of all 6 GiB.
- Android's device tree identifies Google UFS, Verisilicon DC9x00 display and a Google DCSDB panel. Notes report 1080 × 2424 panel geometry and UFS MMIO at `0x3c2d0000`; neither is a complete controller specification or a verified boot framebuffer.
- The static vendor DTBs and Android runtime FDT differ substantially, including memory and UART configuration. Serial routing and a usable pre-OS framebuffer remain unresolved.

## 3. Architecture to keep

Continue with the route that has executed XNU on this phone:

```text
Unlocked CUBS bootloader
    -> temporary Fastboot boot of the stock-shaped boot-v4 image
    -> CUBS ARM64 shim: entry state, FDT validation, memory placement
    -> HackiOS XNU 8796.121.2 with explicit CUBS platform data
    -> a small RAM root and diagnostic userspace
    -> full iOS system image through a separately proven transport
    -> display, input and the first interactive iOS session
```

Use Bluejay for its demonstrated Pixel direct-shim design and HackiOS for reusable XNU/userland/filesystem work. Their GS101 and Qualcomm addresses, clocks, UFS sequences, PMIC operations and touch protocols are reference implementations, not CUBS constants.

Keep the older UniXNU/iPadOS 17 work isolated. It helped expose build prerequisites but is a different kernel/userland branch. Do not mix its binaries or generated ABI artifacts into the iOS 16.5 baseline.

A CUBS UEFI port remains an alternative if it solves a concrete missing service such as staged USB loading. It should not displace the existing direct boot route merely because earlier notes expected UEFI. A UEFI `GetMemoryMap` is relevant only if UEFI is actually in the selected boot chain; the direct route needs its own memory ownership evidence.

## 4. Milestone A — preserve a reproducible baseline

**Purpose:** make every later result attributable to exact source, toolchain and image inputs.

1. Snapshot the current Mac modifications and diagnostic scripts without resetting or cleaning the existing checkouts. Preserve the known-good CP91 image and its matching kernel/symbols separately from the new CP100–114 build.
2. Record source commits, uncommitted diffs, submodule revisions, Xcode/SDK versions, Apple and Homebrew compiler versions, Python, linker and LZ4 versions. Hash generated ADTs, payloads, kernels and final boot images.
3. Turn the current temporary source-edit scripts into a reviewable CUBS patch series or branch. Keep diagnostic instrumentation distinguishable from functional platform changes, and make patch application fail when source anchors no longer match.
4. Resolve the build wrapper's nonzero exit. The current invocation compiled `bsd_init.o`, linked and stripped the kernel, then failed export/import symbol-list checks. Preserve that distinction in manifests. Investigate whether the generated symbol lists, SDK headers or build target selection are inconsistent; do not globally suppress export checking or hide the exit status.
5. Establish one documented build command and one artifact manifest. A release candidate must have a successful supported build invocation, not just an output file left behind after a failed wrapper.
6. Keep the Mac awake for bounded build/observation jobs, log job identity and output remotely, and make reconnection report the existing job before starting another. SSH interruption must not trigger a duplicate device run.

**Exit evidence:** a preserved diagnostic baseline can be rebuilt from recorded inputs; a clean build succeeds or an explicitly scoped kernel target succeeds with the unrelated failed target explained; its symbols match the emitted kernel. Existing user edits remain recoverable.

## 5. Milestone B — locate and fix the first `bsd_init()` blocker

**Purpose:** trace the remaining path from `sysctl_mib_init()` through IOKit/BSD autoconfiguration, time setup and root mounting, while distinguishing a pre-root hang from the expected absence of a root filesystem.

### Immediate experiment sequence

1. CP114 is not confirmed: after the confirmed CP113 marker, the CP114 image returned with an APC watchdog and early-panic boot reason. Inspect XNU's `vfs_mountroot()` path and the no-root behavior before another device run.
2. Add a diagnostic checkpoint before `vfs_mountroot()` and, if practical, inside its root-device wait/mount stages. Preserve the CP114 image as evidence; do not interpret its 10.100-second USB disconnect alone as reaching the return marker.
3. The current image has no root filesystem. Determine whether `vfs_mountroot()` waits forever for a root device, returns an error, or reaches later code; a small RAM root/diagnostic init may be required before CP92 can be meaningfully tested.
4. After obtaining a clean CP114 return or a root-mount trace, run CP92 (return from `bsd_init()`) with the same fixed-kernel build. Preserve image hash, USB trace, Android boot reason and pstore.
5. CP110/111/113/115/116 provide clean same-kernel controls. If a future CP114 marker or root-mount stage fails, bisect only that interval before adding hardware-driver changes.
5. Improve observability enough to capture XNU's last stage and PC/LR. Current pstore can identify a bootloader watchdog reset but cannot distinguish an infinite loop, panic, lock wait or firmware dependency.
6. Apply a functional fix only after identifying the missing prerequisite or invalid assumption. Record the original source, patch, build exit, symbols and image hashes.
7. After any source change, re-run a same-build positive control, the former failing point, and the next downstream point. Keep one variable per experiment and retain every old image.

If CP91 or CP100 fails on the new build, investigate that regression before continuing the `bsd_init()` search. If a selected checkpoint's PSCI call returns or faults, classify it as an instrumentation problem instead of interpreting the watchdog as a source-location result.

### 2026-10-24 root-wait result and marker change

- Checkpoints must now return the phone to Android without a person. `SYSTEM_OFF` leaves it off, and plain `SYSTEM_RESET` is handled as a crash reset (`kernel_panic,early` even when the marker is reached). `loader_checkpoint()` now issues PSCI `SYSTEM_RESET2` with vendor reset type `0x80000001` and cookie `0xcb05c0de`, which reads `ro.boot.bootreason=reboot`. A checkpoint that is not reached reads `kernel_panic,early` after the watchdog. Judge a run by that reason together with the boot-reason history.
- Results on that build: CP113 `reboot` (control); CP114, CP118, CP122–CP125 `kernel_panic,early`; CP127 `reboot` and CP126 `kernel_panic,early`. CP127 sits in `setconf()` before `IOFindBSDRoot()`, and CP126 after it.
- **The hang is in `IOFindBSDRoot()`, not `vfs_mountroot()`.** It first waits up to 30 s for the `IOBSD` resource, then loops on `IOService::waitForService()` for an `Apple_HFS` root media. With no root media it never returns. So with no root device, `bsd_init()` never reaches `vfs_mountroot()`, and CP92 and beyond cannot run.
- The fix is a root image in RAM, which the kernel reads from `/chosen/memory-map` property `RAMDisk` (`{physical address, size}`, `iokit/bsddev/IOKitBSDInit.cpp`) and selects with boot argument `rd=md0`. This is Milestone E. Its three parts are a root image placed in RAM inside the kernel's static map, the `RAMDisk` property in the ADT, and `rd=md0` on the command line.

### 2026-10-24 Milestone E: RAM root mounted, bsd_init completes

- The stock iOS 16.5 `root.apfs` (4 MiB) is now the md0 root. `mkpayload.py --ramdisk` places it right after the kernel and the ADT carries `/chosen/memory-map/RAMDisk`. Boot arguments are `debug=0x8 keepsyms=1 cpus=1 rd=md0`. The shim is unchanged. Device checkpoints read `reboot` for: `IOFindBSDRoot` returns md0 (CP126), mount succeeds (CP128), root vnode (CP129), `bsd_init` returns (CP92), kernel bootstrap ends (CP93).
- Two diagnostic bypasses apply only to `md*` roots: the early IOBSD wait and `IOSecureBSDRoot`. Both timed waits never return on this bring-up. The likely cause is timer interrupts that are not delivered (the counter does advance, CP136), which is not proven yet. Details are in [PORT_STATUS.md](PORT_STATUS.md).
- Milestone E is not complete. Its last exit item, a diagnostic init that runs and reports, is still open. CP93 stops the boot before the init thread runs, and there is no console. Next: a diagnostic visible through a marker, and the virtual-timer/PPI-27 delivery probe that the timed waits need.

### Current marker map

| ID | Location |
| --- | --- |
| CP100 | `bsd_init()` entry, before `platform_stall_panic_or_spin()` |
| CP101 | After `throttle_init()` |
| CP102 | After `kauth_init()` |
| CP103 | After `process_name("kernel_task", kernproc)` |
| CP104 | After `current_uthread()` |
| CP105 | After `proc_update_creds_onproc(kernproc)` |
| CP106 | After the BSD `kmem_suballoc()` assignment |
| CP107 | After `bsd_bufferinit()` |
| CP108 | After `IOKitInitializeTime()` |
| CP109 | After `vfsinit()` |
| CP110 | After `psem_cache_init()` |
| CP111 | After `sysctl_mib_init()` |
| CP112 | After `bsd_autoconf()`; this includes its IOKit BSD initialization work; package built but awaiting device run |
| CP113 | After `inittodr(0)`; package built and host-validated, awaiting device run |
| CP114 | Immediately after `vfs_mountroot()` returns, before examining its result; package built and host-validated, awaiting device run |
| CP115 | After `knote_init()`; midpoint added for the CP109–CP110 interval |
| CP116 | After `mcache_init()`; failed with the APC watchdog signature on the old build, confirmed shutdown on the early-publication build |
| CP117 | After `proc_uuid_policy_init()`; midpoint to isolate CP109–CP116 |

CP114 does **not** prove root mounted successfully: it fires on an error return too. The present image has no root filesystem, so an eventual root-device wait or mount failure is expected even after earlier startup issues are fixed.

**Exit evidence:** the first failure is localized and explained, and XNU reaches the intended root-device discovery point with a readable status. Completing `bsd_init()` itself depends on the RAM-root milestone below.

## 6. Milestone C — make failures observable

Start this alongside the blocker investigation. Repeated dark-screen boots and firmware reboot reasons are too coarse for the remaining driver work.

1. Give each test a run ID and manifest containing source/kernel/image hashes, selected checkpoint, boot arguments and expected outcomes. Save the entire USB trace, not just the console summary.
2. Extend the observer to capture boot reason, uptime, product, boot history and pstore **as soon as authorized ADB returns**. The extended timeout is useful while the device is absent; there is no diagnostic benefit in repeatedly waiting another three minutes after Android is already back and the evidence is available.
3. Save the previous pstore before another boot. Separate the bootloader's reset history from XNU text. `kernel_panic,early` plus the APC watchdog trace does not reveal whether XNU was spinning in a panic, deadlocked, waiting for hardware, or stalled for another reason.
4. Add a bounded early XNU log buffer and a minimal checkpoint/fault record. The buffer must have explicitly reserved memory, stable ownership and cache handling. Record CPU/EL, last stage, PC/LR and relevant exception state when available, without requiring a fully initialized console.
5. Choose a log extraction route and prove it independently: retained RAM read from recovery only after retention/ownership is demonstrated; verified framebuffer output; a correctly routed UART; or a later USB debug channel. Do not assume arbitrary RAM survives a reset or that Linux ramoops automatically contains XNU logs.
6. The upstream ordinary loader-return path assumes 4 KiB XNU pages. The active build uses 16 KiB and currently replaces the selected C checkpoint with direct PSCI `SYSTEM_OFF`. Audit the 16 KiB return/exception path before relying on upstream timed-return or panic extraction features.
7. Keep success, panic, timeout and failed `SYSTEM_OFF` distinguishable. Validate the diagnostic with a deliberate controlled failure and a known successful checkpoint.
8. Identify the watchdog actually causing the reset. The Google Linux watchdog nodes and their stop sequence are not proof of control over the firmware APC watchdog. Prefer a documented servicing/lifecycle arrangement; any temporary disable must be based on the exact controller and leave a bounded recovery route.

**Exit evidence:** one known good run and one controlled failure yield independently identifiable records; the selected transport can recover a useful log or fault location, and the watchdog behavior is measured beyond a single timeout.

## 7. Milestone D — qualify the CUBS kernel platform and memory

**Purpose:** replace the incidental success of a generic configuration with explicit, measured platform support.

1. Inventory what the working shim and ADT actually supply and what the BCM2837 configuration still assumes. Introduce a CUBS board configuration incrementally, comparing it with the preserved startup baseline after each change.
2. Capture the actual incoming Fastboot FDT's relevant memory/reservation and hardware properties through the diagnostic path. Compare them with Android captures and the static vendor DTBs. Keep device-unique calibration and keys as private runtime data.
3. Build an interval ledger for the decompressed shim, source payload, destination XNU segments, stack/vectors, ADT, boot arguments, tables, logs, RAM disks and firmware reservations. Validate arithmetic, alignment and every overlap before copying or mapping anything.
4. Keep the low bank and upper bank separate. Keep the current 6 GiB cap until the bootstrap mappings, real available memory and userspace budget justify a change. Android `System RAM`, `/proc/iomem` and the absence of fixed FDT reservations are useful evidence but do not individually establish bootloader-time ownership.
5. Read the boot CPU feature registers in a diagnostic context to confirm physical-address range and the required translation granules. Verify MMU attributes, cache maintenance and address conversions for high physical memory.
6. Validate interrupt and time behavior: GIC distributor/redistributor layout and stride, timer interrupt IDs, actual counter frequency, timer delivery, sleep/wakeup and scheduler progress. Returning from initialization code is insufficient evidence for this step.
7. Map only required device regions with appropriate device attributes. Do not inherit a broad Qualcomm peripheral window or use an Android-enabled UART as proof of pre-OS serial routing.
8. Keep one CPU active until logging, timer interrupts, root mounting and userspace are stable. Add secondary CPUs later using measured MPIDRs, PSCI and coherency behavior.

**Exit evidence:** a CUBS-configured kernel runs a periodic timer and scheduler/VM diagnostic for at least five minutes, with useful logs and no unexplained watchdog, mapping fault or memory corruption; the result repeats across three boots. These are proposed acceptance checks, not results already achieved.

## 8. Milestone E — boot a small RAM root and diagnostic init

This should precede a CUBS UFS driver. It separates kernel/userspace support from storage-controller development.

1. Use the filesystem and memory-device mechanisms already supported by the selected HackiOS kernel. Inspect the exact RAM-disk ADT properties, root-device discovery and `rd=md0` handling before implementing the direct shim handoff.
2. Extend the payload format and loader to carry a **small** root image. Keep its storage and expanded size within the verified boot-image and RAM budgets. A small root can fit the current diagnostic envelope; the full system image cannot be assumed to fit.
3. Place the RAM disk in memory valid for the kernel's static mapping and lifetime, update `topOfKernelData` and relevant metadata consistently, and exclude it from allocatable VM pages. Cross-check the existing HackiOS loader's RAM-disk rules instead of copying only the `rd=` boot argument.
4. Start with a diagnostic `/sbin/init` or the upstream minimal init path. Match the target Mach-O architecture, platform, page size and execution model; an arbitrary macOS ARM64 executable is not a substitute. Its first job is to report that userspace executed and exercise a small set of syscalls/process operations.
5. Mount the RAM root read-only initially. Log the selected root device and actual mount result. Confirm a root vnode, completion of `bsd_init()`/CP92, and a successful userspace `exec` separately.
6. Verify that the minimal root's libraries and executable dependencies are actually present. The existing 4 MiB `root.apfs` is an input to examine, not proof that all first-process dependencies fit inside it.

**Exit evidence:** XNU names and reads the RAM device, mounts root successfully, reaches CP92 with the selected diagnostic, and a subsequent normal run executes the diagnostic init with useful output beyond the watchdog interval.

## 9. Milestone F — solve full-system image transport

This is a critical architectural decision, not a packaging detail. The current boot wrapper is 64 MiB, while `system.apfs` is about 2.32 GiB. Having 12 GiB of installed RAM does not by itself provide a way to transfer that image into safe RAM.

First measure the actual upload limit and usable boot payload span, decompression destinations, all retained copies, kernel residency and the RAM left for iOS. The previously estimated 5.125 GiB resident-image budget comes from the **UEFI HackiOS loader's layout**; it is not an allocation already available in the direct CUBS shim.

Compare the following routes with small prototypes before committing to one:

| Route | Required proof | Main tradeoff |
| --- | --- | --- |
| Direct shim with staged USB loading | A CUBS USB path accepts a second payload, verifies its hash and retains it in the reserved RAM region | Preserves RAM-based testing, but needs controller/PHY/DMA support or an existing usable service |
| Direct shim with CUBS UFS reads | A read-only driver discovers the controller/LUNs and reads a known test extent through the actual boot handoff state | Provides a route to large images, but adds clocks, resets, power, PHY and possible IOMMU work |
| CUBS UEFI plus HackiOS loader | A separately proven CUBS firmware can boot and supply the memory/USB services the loader needs | Reuses more loader behavior, at the cost of a substantial additional firmware port |
| Deliberately smaller userspace image | A documented subset actually meets a chosen headless milestone within measured limits | Useful for staged progress; it does not make the full lock-screen image fit automatically |

For UFS, use CUBS hardware documentation and vendor driver evidence to establish clocks, resets, power, interrupts, DMA addressing and controller quirks. Begin with identification and read-only bounded reads, compare the data with Android captures, and check for timeouts and IOMMU faults. A standard UFS interface does not imply a GS101 or Qualcomm initialization sequence works on Malibu.

Do not transplant the `ios-sweet` guide's `userdata` flash step. Android userdata encryption, partition ownership and the root-image location need an explicit storage design. If persistent test storage is eventually selected, inventory the exact target, preserve the relevant backups and define recovery before implementing it.

**Recommendation:** prove the small RAM root first, then compare staged USB and read-only UFS using measurable prototypes. Keep the direct boot route unless an alternative demonstrates a concrete advantage.

**Exit evidence:** the chosen path makes the full selected system image available to XNU, verifies its contents, and leaves a measured memory budget for userspace. The method is repeatable and documented.

## 10. Milestone G — bring up iOS 16.5 userspace headlessly

1. Freeze one IPSW/userland build manifest, kernel revision and set of generated images. Keep the older iOS 16.7.16 extraction and iPadOS inputs separate. Change versions only as a deliberate branch migration with its own validation.
2. Verify the full root/system layout, filesystem features, mount arguments, dyld and shared-cache paths, cryptex expectations, writable `/private/var`, permissions and launchd job configuration.
3. Start the upstream minimal init/launchd sequence with captured stdout, kernel and process crash logs. Resolve failures one service at a time: Mach-O loading, dynamic linking, Mach IPC, process startup, filesystem access and required kernel interfaces.
4. Audit Apple-specific platform assumptions and security-policy integration from the selected upstream port. Keep every development adaptation explicit and scoped; do not replace diagnosis with broad global stubs that merely advance to a later crash.
5. Identify required services for BackBoard/SpringBoard before starting the full job set. Disable genuinely absent optional hardware jobs through documented configuration rather than allowing uncontrolled restart loops.
6. Use a host/QEMU reference build where supported to distinguish a userspace image regression from a CUBS hardware problem. A reference boot validates that reference environment only.

**Exit evidence:** launchd starts on CUBS, an essential service set remains alive, and a simple child process can run and communicate while the filesystem and memory budget remain stable. This can be demonstrated before a screen is working.

## 11. Milestone H — display, input and the first interactive build

Display research can proceed alongside the earlier kernel work once memory ownership is understood. Device display writes should follow verified framebuffer bounds.

### Display

1. Establish whether the bootloader leaves a usable scanout buffer and whether its address/format can be recovered from the actual handoff. Confirm address, size, stride, resolution, pixel format, cache rules and lifetime; panel dimensions alone do not identify a framebuffer.
2. Prove bounded color bars and readable text before implementing an iOS graphics interface. If scanout does not survive handoff, document the DC9x00/panel clocks, power, PHY and command sequence needed to maintain it.
3. Supply correct `boot_args.Video`/ADT data and implement the framebuffer/IOSurface interfaces required by the chosen userspace. Validate page mapping, cache visibility and buffer ownership.
4. Use the upstream software rendering path where it exists and is compatible. A visible framebuffer is separate from accelerated rendering, and neither establishes Metal support.

### Input and basic device operation

1. Identify CUBS's actual touch controller, bus, interrupt, reset and supply requirements. Port the protocol from matching vendor evidence; do not assume the Snapdragon guide's Goodix controller or PMIC sequence applies.
2. Validate raw coordinates, orientation, bounds, multi-touch reports and delivery to the iOS input stack. Establish a usable input method before calling the build interactive.
3. Add power/volume keys through the correct CUBS controller. Establish battery reporting, charging behavior and thermal handling sufficiently for sustained testing; power management is part of a usable prototype.

**Exit evidence:** BackBoard/SpringBoard reaches the lock screen, display updates and input reaches the UI, the session stays responsive for five minutes across three boots, logs are recoverable, and the documented return-to-Android path works.

## 12. After the first interactive boot

Prioritize by dependencies and user value:

| Workstream | First useful acceptance check |
| --- | --- |
| USB debugging/data | Stable logs and bounded file transfer under the running kernel |
| Storage persistence | Verified reads, filesystem consistency and controlled writes to the designed test storage |
| Wi-Fi | Correct firmware/controller initialization, association, DHCP and sustained traffic through the iOS networking interface |
| Audio | Working output route with stable clocks/DMA; microphone as a separate step |
| Power and suspend | Correct charging/battery/thermal reporting, controlled idle and repeatable suspend/resume |
| SMP/performance | Each secondary CPU starts through PSCI and passes interrupt/coherency tests before increasing the normal CPU count |
| Bluetooth/sensors | One device/protocol at a time, connected to the appropriate userspace service |
| GPU/Metal | A separate feasibility study of the actual CUBS GPU, firmware, memory model and userspace API integration; measurable rendering is required before making support claims |
| Cellular/cameras/secure hardware | Separate feasibility and driver projects; existing Apple interfaces and vendor firmware dependencies must be established individually |

GPU acceleration, cellular, camera and secure-hardware equivalence may require substantially different work from the boot port. Track feasibility findings and partial support explicitly instead of promising that the lock-screen milestone implies eventual full compatibility.

## 13. Test and evidence rules for the remaining work

- Keep current bring-up submissions as temporary `fastboot boot` tests with the stock Android fallback intact. Check the exact serial, product, classic bootloader mode and image SHA-256 in the runner.
- Maintain one device owner and one active boot job. Other contributors can build or analyze source, but cannot independently reboot the same phone.
- Record an expected positive outcome, expected failure outcome and observation deadline before each boot. Use a known positive control after any kernel or handoff change.
- When the phone is absent, let the bounded passive watcher finish before a manual power action. If Android returns automatically, capture evidence immediately. If manual recovery is needed, record the exact action and stop holding Power once startup is visible so a second forced reset does not replace the evidence.
- Run the existing FDT/window, Mach-O/payload, ARM64 Image, relocation/undefined-symbol, legacy-LZ4 and stock boot-v4 checks for changed candidates. Validate RAM-disk metadata and overlap accounting when those are added.
- Keep negative controls intentional and limited. Do not repeat identical failed binaries without a new hypothesis or new evidence channel.
- Preserve old images and matching symbols. A run record should contain checkpoint/result, source and artifact hashes, boot arguments, timestamps, USB transitions, manual actions, Android boot reason, pstore hash and a concise interpretation with uncertainties.
- Keep raw device trees, calibration data, keys and IPSW-derived contents out of a public source release. A release should provide source, versioned patches, manifests and a reproducible local build recipe.

## 14. Parallel work and decision gates

Parallel work is useful after the baseline snapshot:

| Lane | Independent work | Integration boundary |
| --- | --- | --- |
| Kernel/build | Same-build controls, first failing call, toolchain/export audit, CUBS config | Own active XNU source edits and kernel artifact manifest |
| Diagnostics/memory | Handoff inventory, interval ledger, log/exception record, observer improvements | Agree on reserved memory and boot metadata with the kernel lane before device use |
| Root/transport | Minimal init/root, APFS compatibility, full-image transport prototypes | Share a versioned payload format and memory budget; no speculative image placement |
| Display/input | Vendor-source analysis, framebuffer ownership, touch protocol | Device MMIO work begins only after exact ranges and the diagnostic/recovery path are ready |

Only the device owner runs a candidate, after its producer supplies the manifest and expected result. Avoid two contributors editing the same loader or source file concurrently. Merge small changes and preserve the same-build control.

The critical path is:

```text
Reproducible baseline + same-build positive control
    -> precise startup blocker + useful diagnostics
    -> qualified memory/platform + small RAM root
    -> diagnostic init
    -> full-system image transport + iOS services
    -> display/input integration
    -> first interactive build
```

Display research and transport feasibility should run early because either may reveal a major constraint. Full GPU and peripheral work should not delay the first headless userspace milestone. Assign calendar estimates only after the first startup blocker and large-image transport have concrete solutions.

## 15. Next development session: ordered checklist

1. Done (2026-10-24): the no-root wait is in `IOFindBSDRoot()`, reached from `setconf()` (CP127 reached, CP126 not). `vfs_mountroot()` is not reached without a root device. See "2026-10-24 root-wait result" above.
2. Next artifact: a diagnostic RAM root (Milestone E) passed through `/chosen/memory-map` `RAMDisk` with `rd=md0`. Do not run CP92 or later before this exists, because they cannot be reached without a root.
3. Runs now use the `SYSTEM_RESET2` marker and return to Android by themselves. If a run does not return within the observer's window, record it and stop; do not assume the phone is in Fastboot. Only then ask for a single Power press, and once it is visible, stop holding Power so a second forced reset does not replace the evidence.
3. Preserve CP100–CP114 logs, pstore, kernel hashes and source/toolchain snapshot at `$HOME/unixnu-pixel11/cubs-xnu-bootstrap/out/snapshots/20261024-cubs-xnu-cp117/`; add the early-CPU-publication source, CP112–114 manifests and image hashes without replacing prior evidence.
4. After the checkpoint chain is clear, run a same-kernel diagnostic that reports the current `mountroot`, root-device selection, and any return code. Do not write the iOS APFS image to Android storage.
5. Complete the XNU export/install audit, verify exact symbols, and make the scoped build and package commands reproducible.
6. Build a small RAM root and diagnostic init only after establishing a safe memory handoff and a loader transport that can deliver the root image. Then qualify the CUBS UFS discovery path or another verified RAM transport.
7. Continue platform memory/timer checks and display/transport feasibility work alongside headless startup; retain the existing RAM-only Fastboot test boundary.

## Appendix A — environments, source and files

**Windows workspace:** `<workdir>`

**Mac:** `<user>@<lan-ip>`; observed Xcode path `/Applications/Xcode-27.0.0-Beta.3.app`. SSH uses the existing task-local key; preserve it privately and do not include private key material in a report or source commit.

| Item | Location |
| --- | --- |
| Active HackiOS checkout | `$HOME/unixnu-pixel11/hackios-upstream` |
| Active XNU source | `$HOME/unixnu-pixel11/hackios-upstream/xnu-src/xnu-8796.121.2` |
| CUBS diagnostic project | `$HOME/unixnu-pixel11/cubs-xnu-bootstrap` |
| Active shim/builder/runner | `$HOME/unixnu-pixel11/cubs-xnu-bootstrap/direct-xnu-checkpoint10/` |
| Passive observer | `$HOME/unixnu-pixel11/cubs-xnu-bootstrap/out/checkpoints/ram_boot_with_watch.sh` |
| Checkpoint artifacts and phone evidence | `$HOME/unixnu-pixel11/cubs-xnu-bootstrap/out/checkpoints/cpNNN-psci/` |
| CP100–114 build log | `$HOME/unixnu-pixel11/cubs-xnu-bootstrap/out/logs/cp100-114-xnu-build.log` |
| Source instrumentation helper | [apply_bsd_init_checkpoints.py](C:$HOME/Documents/Codex/2026-10-20/ho/ios-cubs-port/tools/apply_bsd_init_checkpoints.py); also copied to Mac diagnostic `out/` |
| Shim/builder limit helper | [apply_checkpoint_range.py](C:$HOME/Documents/Codex/2026-10-20/ho/ios-cubs-port/tools/apply_checkpoint_range.py); also copied to Mac diagnostic `out/` |
| Generic iOS 16.5 images locally | `<workdir>` |
| Older confirmed checkpoint images | `<workdir>` |

The Mac source, loader and builder backups made before CP100–114 have suffix `.pre-cubs-cp100-114.20261024-000520`. The preceding checkpoint insertion has separate backups under `out/source-backups/post-cp21/`. Preserve both sets.

Current observed source commits, which must be accompanied by their uncommitted diffs:

- HackiOS checkout: `8e61187098f2c26c5daee8f9f72b6416aa64b9ab`.
- XNU checkout base: `c54f35ca767986246321eb901baf8f5ff7923f6a`.
- CP100–114 stripped kernel SHA-256: `60c3c9435d44bc1473e84340828b63e0fe6f238c9ebf8d860ddca9e5d410a5bc`.
- Matching unstripped kernel SHA-256: `e8fa2456b6cd19a14f58f9d2a8500a0ecd1dc06c9ff5160fe0a9ef7f296eb0e3`.
- Stock boot template SHA-256: `8e4c29a524adfe1e0ee7ae554bc04e90d36a2c79f69b5c88c0be836dbdc6d972`.

Observed build environment setup, to recheck against the manifest before use:

```sh
export DEVELOPER_DIR="/Applications/Xcode-27.0.0-Beta.3.app"
export PATH="/opt/homebrew/opt/unifdef/bin:/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/llvm/bin:$PATH"
```

ADB and Fastboot on the Mac are `/opt/homebrew/bin/adb` and `/opt/homebrew/bin/fastboot`. The runner currently checks the serial/product, reboots authorized Android to the bootloader, boots the hashed image temporarily, then observes. Review its current behavior when improving the observer so passive monitoring does not accidentally become a new boot action.

## Appendix B — diagnostic hashes

These are diagnostic artifacts, not full iOS system images. Each packaged boot image is 67,108,864 bytes.

### Current early-publication build

| Checkpoint | Boot-image SHA-256 | Device result |
| --- | --- | --- |
| CP100 | `9f3a428127bb2d06ae064cf7e7db8f0f34535a3df987124a79f62be8f89e8af2` | Shutdown; empty pstore |
| CP110 | `bec5b70bd2b8be441510ed406c4973567430c576a56889b607ea46818fc259d7` | Shutdown; empty pstore |
| CP111 | `56b9fd18aaba796bc3e0e1672d6243820438852c88a2ec798b07781b6bc5d082` | Shutdown; empty pstore |
| CP112 | `1589b3fdf961878ace318b912904f244bfd23de4ab4e94c25c96873f381264e4` | USB gone at 12.528s; black/off; later boot reason overwritten to `reboot`, so probable only |
| CP113 | `70503b5d8c2ed271a7af463ba96fdcd5f1db109c4260994422330b48f34137c0` | Shutdown; product `cubs`; empty pstore |
| CP114 | `8f177d6ed41b9f23b2e107aa631c6930f46b0844d1389b876eafd2a59d16b38d` | `kernel_panic,early`; APC WDT `0xcbea`; pstore SHA-256 `b6edf26eb663e9e733f2349db844345f0c95c2334f2aa40ae802707aea0893b3` |
| CP115 | `2a826a2d21e7cdfa65c68debb093ea7313e6beadbcbe9865b73a4df2773523bd` | Shutdown; empty pstore |
| CP116 | `9cdb59b2344f974c200a1aa515c84bd651375cc7fa7b12039efcfe1838e77b4b` | Shutdown; empty pstore |

### Superseded pre-fix package hashes

| Checkpoint | Boot-image SHA-256 | Saved pstore SHA-256 |
| --- | --- | --- |
| CP110 | `23b72fd1bca7352777f6d4e54a9ae213c429b664de2c382bf3ed5340f55d0aec` | `5dfb393e5a8b6d12d0cbf79593ee524a05bb409a4771b6106433d1d254860943` |
| CP111 | `cb8092e3c3107f202df28c1ed88cf1fcded5ef0c3f3916db46c8003db44d79fc` | `7ae163857372c05caba74291dddfb37785096aaec74bf11ee1cbcc9f95e0da67` |
| CP112 | `77ec3298bda7a0d027531e2b843d172651d0759c87da4c86d64fcab6f86bd775` | `a99378021dc0de3087ab5560cfbdcd7d38db84aaecb1fd53998a72760f4ccb23` |
| CP113 | `00d8ebde25252bbe3dcd907cd90213d27fc9163ef9b7ac30acc5987e6da4f679` | `23ba5a592204846292309433947307c0493464a29ae28bf53eaa66774304d22e` |
| CP114 | `4fcccc82a6b1001d495c0d6d665d371647120af980560457894e1a6a9bfb5cc6` | `5704e32794eca5a33a43348443fd2a734ad0ff23395f64b8549bebfe5b58e860` |

## Appendix C — supporting project references

- [PORT_STATUS.md](C:$HOME/Documents/Codex/2026-10-20/ho/ios-cubs-port/PORT_STATUS.md): detailed run history; newest dated sections take precedence over earlier snapshots.
- [HACKIOS_CUBS_MEMORY_REVIEW.md](C:$HOME/Documents/Codex/2026-10-20/ho/ios-cubs-port/HACKIOS_CUBS_MEMORY_REVIEW.md): RAM banks, reservation evidence and the distinction between Android and loader-time memory ownership. Its UEFI-specific allocation prerequisites do not apply unchanged to a direct shim.
- [HACKIOS_UPSTREAM_REVIEW.md](C:$HOME/Documents/Codex/2026-10-20/ho/ios-cubs-port/HACKIOS_UPSTREAM_REVIEW.md): reusable HackiOS components and Qualcomm/Tensor differences.
- [CUBS_BLUEJAY_BOOT_PATH.md](C:$HOME/Documents/Codex/2026-10-20/ho/ios-cubs-port/CUBS_BLUEJAY_BOOT_PATH.md): direct Pixel shim design, stock packaging comparisons and EL/FDT probes.
- [Earlier checkpoint build notes](C:$HOME/Documents/Codex/2026-10-20/ho/outputs/cubs-xnu-checkpoints-2026-10-23/BUILD_NOTES.md): earlier confirmed checkpoint artifacts.
- Source baselines reviewed in this project: [HackiOS kernel](https://github.com/oosexgang/hackios-xnu-kernel), [HackiOS userland](https://github.com/oosexgang/hackios-xnu-userland), and [iOS Bluejay](https://github.com/dristotle/ios-bluejay). Treat their documented device results as upstream claims; CUBS acceptance depends on this project's own device evidence.
