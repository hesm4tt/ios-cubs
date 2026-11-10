# Pixel 11 (cubs) iOS port status

## 2026-10-24 timer-interrupt probe: why timed waits never return

Each result is one fastboot boot that returned to Android by itself; `reboot` = the checkpoint was reached.

| Checkpoint | What it tests | Result |
| --- | --- | --- |
| CP140 / 141 / 142 | IRQs masked, timer armed 1 ms: GIC highest-pending is INTID 27 / timer fired but no INTID 27 / timer never fired | 140 reboot: **PPI 27 reaches the CPU interface** |
| CP145 / 146 | PSTATE.I at the start of the probe | 146 reboot: IRQs are unmasked in `bsd_init` |
| CP151 / 152 / 150 | `CNTKCTL_EL1.EVNTEN` / masked `WFE` returns | 151 reboot (event stream on); 150 reboot (WFE wakes) |
| CP153 | `IODelay(1000)` returns | reboot, but this is a **spin** (`ml_delay_should_spin`), not a block |
| CP168 / 169 | PSTATE.I just after that 1 ms delay | 168 reboot: **IRQs are left masked** |
| CP158 | the IOBSD wait, exact 0.1 s timeout, called from the probe | kernel_panic (never returns) |
| CP164 / 165 / 166 / 167 | function entry / after preamble / before and after `serviceMatching()` | 166 reboot, 167 kernel_panic: `serviceMatching(gIOResourcesKey)` hangs while IRQs are masked |
| CP167 (IRQs re-enabled after the delay) | same call with `msr daifclr, #2` after the delay | **reboot**: the masked IRQ state is what hangs `serviceMatching()` |
| CP158 (same IRQ re-enable) | the 0.1 s IOBSD wait | still kernel_panic |
| CP170 / 171 | IRQs unmasked, VTIMER armed 20 ms, count of VTIMER IRQs taken in `gic_irq_handler` during a 30 ms counter spin | 170 reboot: **the timer IRQ is taken and dispatched** |
| CP170 / 171 (earlier, `IODelay(20000)` for the wait) | a 20 ms timed block with IRQs unmasked | kernel_panic: the block never returns |

**What is established**
- The GIC and the virtual timer work: PPI 27 is asserted, taken with IRQs unmasked, and dispatched to `rtclock_intr`.
- The idle-path event stream works, and masked `WFE` returns.
- A timed block of 20 ms, with IRQs unmasked and the interrupt taken normally, does not return. So the stall is in the scheduler's deadline path (the rtclock arming a deadline for `thread_block`, or the idle wake), not in interrupt delivery.
- IRQ state leaks: after the 1 ms spin, PSTATE.I is set (CP168). A masked IRQ state stops `serviceMatching()` from returning. That's a second, separate fault that surfaces the same symptom.
- My earlier claim that a 1 ms timed block returns was wrong: it is a spin. The "timed waits never return" symptom therefore has two parts: the scheduler's timed block, and an IRQ mask that is not restored.

**Not established**
- Whether a block arms `CNTV_TVAL` at all. The next probe should log the value of `ml_set_decrementer` on each call, and check the rtclock deadline it computes.
- Where PSTATE.I is set after the spin. `machine_delay_until()` (osfmk/arm/rtclock.c) does not touch the mask, so the source is elsewhere; checking the exception-return path is the next step.

- CP172 / CP173: after a timer IRQ is taken with IRQs unmasked, CP173 reboot means PSTATE.I is clear again. The IRQ return path is therefore not the source of the masked state seen after the spin (CP168).

- Timebase ruled out: the CUBS ADT CPU nodes are `state=running` with `timebase-frequency=999990000`, so `pe_identify_machine.c` uses the right rate and the 24 MHz default is never applied. The `setPop`/`SetIdlePop` path has `cpu_idle_latency=0`. The remaining suspect is the block-to-wake handoff in the scheduler, not the clock configuration.

- Scheduler localization (CP180–CP197): `mach_absolute_time()` advances (CP193). A WFE-and-time spin for 20 ms returns (CP195). So the 20 ms `IODelay` takes the block branch of `_clock_delay_until_deadline_with_leeway()`, and `thread_block()` is entered (CP196) but does not return (CP197). `cpu_idle()` and `machine_idle()` are never entered (CP180–CP184), so the stall is in the scheduler's switch path before the idle thread runs. The event-stream check (CP190/191) was miscalibrated: EVNTI 9–15 means a period of at most about 65 µs, so it does not explain the stall. Next probe, if continued: inside `thread_invoke()` / `thread_select()` for the blocked thread.

**Source state.** The probes and the re-enable experiment are in the Mac tree now (`iokit/bsddev/IOKitBSDInit.cpp`, `iokit/Kernel/IOService.cpp`, `osfmk/arm64/gic_v3_irq.c` with `cubs_vtimer_irq_count()`). Backups: `IOKitBSDInit.cpp.pre-timerprobe`, `IOService.cpp.pre-waitprobe`, `IOKitBSDInit.cpp.pre-ramroot`. The `gic_v3_irq.c` file was edited in place and has no backup of its own from before this session. Remove the probes before any release build.

## 2026-10-24 RAM root (Milestone E): md0 mounts, bsd_init returns; no userspace yet

- **Root image.** The HackiOS iOS 16.5 `root.apfs` (4,194,304 bytes, SHA-256 `dffb588c498321b7…`, `~/unixnu-pixel11/hackios-upstream/userland/root.apfs`) is passed to the Bluejay `mkpayload.py --ramdisk` path that the builder already calls. The image becomes one payload segment right after the kernel: physical `0x882360000`, size `0x400000`. `/chosen/memory-map/RAMDisk` = `{0x882360000, 0x400000}` is in the ADT, and boot arguments are `debug=0x8 keepsyms=1 cpus=1 rd=md0`. The shim is unchanged. The root contains `/sbin/init` (mode 0755).
- **Builder.** `build_cubs_xnu_image.sh` now takes optional `CMDLINE` and `RAMDISK` environment variables. Defaults are unchanged. Old copy: `direct-xnu-checkpoint10/build_cubs_xnu_image.sh.pre-ramroot`.
- **Device results.** Each run was fastboot boot only and returned to Android by itself. `reboot` = reached.

  | Checkpoint | Stop point | Result |
  | --- | --- | --- |
  | CP113 / CP127 | control; `setconf()` before `IOFindBSDRoot()` | reboot |
  | CP133 / CP135 | before the `rd` parse / after the `rd=md*` short wait is chosen | reboot: `rd=md0` is parsed |
  | CP136 | after a 50 ms busy-wait on `cntvct_el0`, before the timed IOBSD wait | reboot: the counter advances |
  | CP130 / CP131 / CP132 | after the IOBSD wait / RAM-disk branch / `mdevadd` | first run of CP130 was not valid (the observer captured the previous boot); the IOBSD wait itself never returned (below) |
  | CP126 | after `IOFindBSDRoot()` returns | reboot: `md0` is found |
  | CP114 | after `vfs_mountroot()` returns | reboot |
  | CP128 | mount loop exited with success | reboot: **the root mounts** |
  | CP129 | after `VFS_ROOT()` (root vnode) | reboot |
  | CP137 | after `IOSecureBSDRoot()` (with the skip below) | reboot |
  | CP92 | after `bsd_init()` returns | reboot: **bsd_init completes** |
  | CP93 | after `vm_free_delayed_pages()`, end of kernel bootstrap | reboot |

- **Two bypasses, both only for `md*` roots, both diagnostic.**
  1. `IOFindBSDRoot()`'s early IOBSD wait (`waitForMatchingService`, timed) never returns on this bring-up. The `rd=md0` check selects its short 0.1 s timeout, and CP136 shows the counter itself advances. The likely cause is that timer interrupts are not delivered, which is not yet proven. The wait is skipped only for `md*` roots.
  2. `IOSecureBSDRoot()` starts with a 30 s timed wait for `IOPlatformExpert` and never returns (CP137 with the skip absent). It is skipped only for `md*` roots, since the secure-root check applies to on-disk roots.
- **Kernel source changes** (uncommitted, Mac): `bsd/kern/bsd_init.c` (CP128/129/137, the secure-root skip; backup `.pre-ramroot`), `iokit/bsddev/IOKitBSDInit.cpp` (CP130–137 instrumentation, the spin, the wait bypass; backup `.pre-ramroot`), `osfmk/arm64/loader_return.c` (SYSTEM_RESET2 marker; backup `.pre-reset2-experiment`), `bsd/vfs/vfs_subr.c` (CP122–125; backup `source-backups/reset-mountroot/`).
- **Images.** CP92 `4151508c2b0231f5…`, CP128 `4272f7511674f7b6…`, CP129 `f7e5420e203c2cc5…` (full hashes in each run folder under `~/unixnu-pixel11/cubs-xnu-bootstrap/out/checkpoints/cpNNN-rs2/`). Kernel stripped SHA-256 `64ee2580e8f42433…` (from the last build).
- **Not done.** No userspace has run: CP93 stops the boot before the init thread can execute, and the kernel gives no console. The next visible milestone needs either a marker the init can write, or a run that continues past CP93. Also needed: the timer/IRQ delivery probe (poll `ICC_IAR1_EL1` for PPI 27 after arming the virtual timer), which is the root cause of both timed waits.

## 2026-10-24 unattended checkpoints: reset terminator and the mountroot bisect

- Requirement from the user: after a RAM-only `fastboot boot`, the phone must restart into Android without a manual power press. The old checkpoint terminator, PSCI `SYSTEM_OFF` (`0x84000008`), leaves the phone off, so it is no longer used for unattended runs.
- **PSCI `SYSTEM_RESET` (`0x84000009`) from XNU is not a usable marker.** The control image CP113 under plain `SYSTEM_RESET` returned to Android by itself (ADB back about 58 s after launch), but `ro.boot.bootreason=kernel_panic,early`. The pstore shows `Crash Reset: Watchdog prep trigger`, `APC WDT sub reason: 0xcbea` and `0xbab9 - Early Kernel PANIC`, the same signature as the earlier hang at CP92 and CP114. Plain `SYSTEM_RESET` is therefore handled as a crash-style reset and cannot be told apart from a watchdog hang.
- **PSCI `SYSTEM_RESET2` with a vendor reset type works as a marker.** `loader_checkpoint()` in `osfmk/arm64/loader_return.c` now calls `SYSTEM_RESET2` (`0x84000012`) with reset type `0x80000001` and cookie `0xcb05c0de`, and falls back to `SYSTEM_RESET` only if that call returns. Control CP113 on this build returned by itself with `ro.boot.bootreason=reboot` and no manual action. The previous `kernel_panic` signature therefore does not appear for a reached checkpoint. Build SHA-256 of the stripped kernel: `2aee5defc3d8f27c…`. CP113 image SHA-256: `c17afdd05a7921a8418917749f5c306048705cec6a38125c8a62ae943c923d6f`.
- Added checkpoints to the Mac tree (`~/unixnu-pixel11/cubs-xnu-bootstrap/out/apply_reset_and_mountroot.py`, originals in `out/source-backups/reset-mountroot/`): CP118 immediately before `vfs_mountroot()` in `bsd_init()`; CP122 at `vfs_mountroot()` entry; CP125 before the `(*mountroot)()` pointer call; CP123 after `bdevvp()`; CP124 before each filesystem's mount attempt. `vfs_mountroot()` contains 4 checkpoint calls and `bsd_init()` 19, as counted in the linked kernel.
- Interpretation to test: `vfs_mountroot()` has no return path when there is no root device, so the CP114 "not reached" result fits a hang inside it. The bisect below tests where the hang begins.
- Results on the SYSTEM_RESET2 build (fastboot boot only; every run ended with Android returning by itself, no manual action; summary in `~/unixnu-pixel11/cubs-xnu-bootstrap/out/checkpoints/rs2-summary.txt`):

  | Checkpoint | Stop point | `ro.boot.bootreason` |
  | --- | --- | --- |
  | CP113 | after `inittodr(0)` (control) | `reboot` |
  | CP114 | after `vfs_mountroot()` returns | `kernel_panic,early` (not reached) |
  | CP118 | before `vfs_mountroot()` | `kernel_panic,early` (not reached) |
  | CP122 / CP123 / CP124 / CP125 | `vfs_mountroot()` entry, after `bdevvp()`, per-filesystem attempt, before the `mountroot` pointer call | all `kernel_panic,early` (not reached) |
  | CP127 | `setconf()`, before `IOFindBSDRoot()` | `reboot` (reached) |
  | CP126 | `setconf()`, after `IOFindBSDRoot()` returns | `kernel_panic,early` (not reached) |

- **Correction to the earlier hypothesis.** The hang is not inside `vfs_mountroot()`. It is inside `IOFindBSDRoot()` (`iokit/bsddev/IOKitBSDInit.cpp`, called from `setconf()` in `bsd/kern/bsd_init.c`). Reading the code: the function first waits up to 30 s for the `IOBSD` resource (`waitForMatchingService`; the wait is cut to 0.1 s only when `rd=md0` is given). It then builds a matching for an `IOMedia` `Apple_HFS` root and loops on `IOService::waitForService()` with no exit while no such media exists. `vfs_mountroot()` is never entered in this image. The CP114 "not reached" result was this same wait, and the watchdog fires during it.
- **Marker rule for unattended runs:** `ro.boot.bootreason=reboot` together with the boot-reason history means the checkpoint was reached. `kernel_panic,early` means it was not (hang, then the APC watchdog). Both outcomes return to Android without a person. Caveat: a reboot issued by the runner or a person also reads `reboot`, so runs should be judged with the USB timeline and the history, not the reason alone.
- **What a real root needs.** `IOFindBSDRoot()` takes a memory-device root from `/chosen/memory-map` → property `RAMDisk` (`{physical address, size}`, read in `IOKitBSDInit.cpp` near line 762), which the function turns into `md0` with `mdevadd`. The boot arguments must then select it with `rd=md0`. The shim and the ADT builder must therefore (1) place a root image in RAM inside the kernel's static map, (2) add `/chosen/memory-map/RAMDisk`, and (3) add `rd=md0` to the boot arguments. That is Milestone E in `DEVELOPMENT_PLAN.md`. It is not implemented yet.
- Not done this session: no fix to the loader or ADT, no image with a root, and no run of CP92 or beyond. The kernel and the shim's checkpoint range now accept 0..199 (`loader.c` and `build_cubs_xnu_image.sh`; pre-change copies in `*.pre-cp118`).
- Source backups: `out/source-backups/reset-mountroot/` (terminator and CP118/CP122–125), `out/source-backups/` for `loader_return.c.pre-reset2-experiment` and `bsd_init.c.pre-setconf-cp`.

## Latest development snapshot and forward plan (2026-10-24)

- The forward plan is [DEVELOPMENT_PLAN.md](C:$HOME/Documents/Codex/2026-10-20/ho/ios-cubs-port/DEVELOPMENT_PLAN.md). It supersedes older next-step instructions, including the CP14-era handoff and the assumption that CUBS UEFI is required before a direct XNU boot.
- Root cause found: both `kperf_init_early()` and `mcache_init()` could wait in `ml_wait_max_cpus()` before the generic `GenericARMPE::start()` publisher ran during IOKit CPU service enumeration. For this diagnostic, the CPU topology is already parsed and `machine_info.max_cpus` is 1. The temporary optional-kperf workaround has been removed. `kperf_init_early()` now publishes that count only when boot arguments contain `cpus=1` and `machine_info.max_cpus == 1`, then retains the ordinary wait for every configuration.
- The scoped build `bash xnu-build.sh build` completed with exit 0. Current stripped kernel SHA-256: `0ca74af57f1255caf8e014a5c0368b861cad5ff5b64ff10da519b71c43cbb299`; unstripped: `04fd1aa9e593e4f40620b7b9b4e7a7522e7d82d96dee2ba556c9041d15a7ed0e`. The helper is [prepare_early_cpu_count.py](C:$HOME/Documents/Codex/2026-10-20/ho/ios-cubs-port/tools/prepare_early_cpu_count.py); the Mac backup is `kperf.c.pre-cubs-early-max-cpus.20261024-012022`.
- On that same kernel, CP100 (BSD entry), CP116 (after `mcache_init()`), CP115 (after `knote_init()`), CP110 (after `psem_cache_init()`), and CP111 (after `sysctl_mib_init()`) each returned to Android with `ro.boot.bootreason=shutdown` and empty pstore. Their boot-image SHA-256 values, in that order, are `9f3a428127bb2d06ae064cf7e7db8f0f34535a3df987124a79f62be8f89e8af2`, `9cdb59b2344f974c200a1aa515c84bd651375cc7fa7b12039efcfe1838e77b4b`, `2a826a2d21e7cdfa65c68debb093ea7313e6beadbcbe9865b73a4df2773523bd`, `bec5b70bd2b8be441510ed406c4973567430c576a56889b607ea46818fc259d7`, and `56b9fd18aaba796bc3e0e1672d6243820438852c88a2ec798b07781b6bc5d082`.
- CP92 after `bsd_init()` still returned with `kernel_panic,early`; its 54,600-byte bootloader log SHA-256 is `fb3e2456d019b29a17e5e262e039d57d37e7f106ab6d59b3d036469038cef8cb`. The log reports `RST_STAT=0x3`, GDMC reason `0xbab9`, APC WDT subreason `0xcbea`; it has no CPU PC context. CP111 succeeds after `sysctl_mib_init()`, so the remaining interval includes `bsd_autoconf()`, later network setup, `inittodr()`, and root mounting. CP112 after `bsd_autoconf()` (image SHA-256 `1589b3fdf961878ace318b912904f244bfd23de4ab4e94c25c96873f381264e4`) was accepted by Fastboot; USB disappeared after 12.528 seconds, and the user saw black/off. The phone later returned to Fastboot and was normally rebooted to Android, so the final `ro.boot.bootreason=reboot` cannot independently confirm CP112's shutdown marker. CP113 after `inittodr(0)` (SHA-256 `70503b5d8c2ed271a7af463ba96fdcd5f1db109c4260994422330b48f34137c0`) is confirmed by `ro.boot.bootreason=shutdown`, `product=cubs`, and empty pstore. CP114 immediately after `vfs_mountroot()` returns (SHA-256 `8f177d6ed41b9f23b2e107aa631c6930f46b0844d1389b876eafd2a59d16b38d`) was accepted by Fastboot; USB disappeared after 10.100 seconds, then Android returned with `kernel_panic,early`. Its 54,834-byte bootloader log SHA-256 is `b6edf26eb663e9e733f2349db844345f0c95c2334f2aa40ae802707aea0893b3`; it reports `RST_STAT=0x3`, GDMC reason `0xbab9`, APC WDT subreason `0xcbea`, and no CPU PC context. CP114 is therefore not confirmed; the failure is consistent with a stall before `vfs_mountroot()` returns, though the missing root filesystem may be responsible and that is not yet proven.
- The source and packaging changes are diagnostics; the candidate still uses the generic BCM2837 build, has no root filesystem, and omits CUBS UFS and display support. All device trials use `fastboot boot`; no Android partition has been flashed, erased, or written.

### CP112–CP114 RAM-only checkpoint run (2026-10-24)

- Mac SSH is available. The existing runner verifies the image SHA and Fastboot product, then runs only `fastboot boot`; no flash or erase command is present.
- CP112 image SHA-256 `1589b3fdf961878ace318b912904f244bfd23de4ab4e94c25c96873f381264e4` was accepted. Fastboot USB disappeared 12.528 seconds later and stayed absent for the 45-second watch. The user saw black/off, pressed Power, and the Pixel appeared in Fastboot. A normal `fastboot reboot` returned Android; ADB reported `ro.boot.bootreason=reboot`, `product=cubs`, and empty pstore. Since that later reboot replaced the original reason, CP112 remains probable but not independently confirmed.
- CP113 image SHA-256 `70503b5d8c2ed271a7af463ba96fdcd5f1db109c4260994422330b48f34137c0` was accepted. Fastboot USB disappeared at 10.331 seconds. The user saw black/off and pressed Power; the observer captured Android at +43 seconds with `ro.boot.bootreason=shutdown`, `product=cubs`, and empty pstore. CP113 is confirmed: `inittodr(0)` returned.
- CP114 image SHA-256 `8f177d6ed41b9f23b2e107aa631c6930f46b0844d1389b876eafd2a59d16b38d` was accepted. Fastboot USB disappeared at 10.100 seconds. Android returned automatically with `ro.boot.bootreason=kernel_panic,early`; `/sys/fs/pstore/console-ramoops-0` is a 54,834-byte bootloader log with SHA-256 `b6edf26eb663e9e733f2349db844345f0c95c2334f2aa40ae802707aea0893b3`. It records `RST_STAT=0x3`, GDMC `0xbab9`, APC WDT subreason `0xcbea`; no CPU PC context is available. This does not confirm CP114. The evidence narrows the failure to the path after the confirmed CP113 marker and before/at the `vfs_mountroot()` return checkpoint, but does not prove the root-mount wait is the cause.
- Next: inspect `vfs_mountroot()` and the no-root behavior, add a checkpoint before the call and narrower root-device/mount instrumentation, and decide whether a small RAM root is required. Defer CP92 until CP114 returns or the root-mount path is made observable. The user asked to pause work after this plan update; no further device action is authorized in this turn.

## XNU startup checkpoint results (2026-10-23)

- A separate CP10 image was built from the modified XNU 8796 kernel. Its
  checkpoint calls PSCI `SYSTEM_OFF` directly, bypassing this tree's ordinary
  loader return hook, which is compiled out for its 16 KiB page configuration.
  Fastboot accepted the 64 MiB stock-header image, USB disappeared 12.473
  seconds later, and after power-on Android reported
  `ro.boot.bootreason=shutdown` with an empty pstore. This confirms execution
  reached checkpoint 10 at the beginning of C `arm_init()`.
- CP11 is immediately after `PE_init_platform(FALSE, args)`. The separately
  built image passed the same live-FDT/RAM-window, ARM64 Image, legacy-LZ4
  round-trip, and stock Android boot-v4 header checks. Its SHA-256 is
  `0e03e8b2c8f33182bb098094f550973bb3ebd175862e20fca140ab08210428b5`.
  Fastboot accepted it and USB disappeared 12.471 seconds later. After a long
  power-button press returned Android, read-only ADB reported
  `ro.boot.bootreason=shutdown` and an empty pstore. This confirms execution
  returned from `PE_init_platform` and reached CP11.
- CP30 and CP31 images passed the same host checks. CP31 is immediately after
  `wfe_timeout_configure()`. Fastboot accepted it, USB disappeared 12.503
  seconds later, and after the user powered Android back on, ADB reported
  `ro.boot.bootreason=shutdown` with an empty pstore. This confirms the timer
  interval calculation returned. CP31 SHA-256 is
  `a8bbf2bd89075aaf4116d0759c3253ebafce263a127627a427aaeca37ef118c4`.
  The CP10, CP11, CP12, CP31, and CP32 stock-header images are saved locally under
  `../outputs/cubs-xnu-checkpoints-2026-10-23/`.
- CP32 stops after `wfe_timeout_init()` enables the event stream; CP12 stops
  after `ml_parse_cpu_topology()`. CP32 was RAM-booted; USB disappeared
  12.476 seconds later and Android then reported `ro.boot.bootreason=shutdown`
  with an empty pstore. This confirms the timer event-stream setup returned.
  CP12 was RAM-booted; USB disappeared 12.465 seconds later and Android then
  reported the same shutdown reason and empty pstore. This confirms CPU
  topology parsing returned. CP32 SHA-256:
  `5b7a689fc3ee51dbc4c83a2ef8e35927667c98990c33b83c9f55004b90a9b6e8`.
  CP12 SHA-256:
  `cb386ab3a72c33b404d0b1de1c3319146589b1ac9788184de19f0e90546b0011`.
- CP42 stops after `thread_bootstrap()`, following boot-CPU selection and
  initial CPU data setup. It was RAM-booted; after Android returned, ADB
  reported `ro.boot.bootreason=shutdown` and an empty pstore. This confirms
  XNU reached CP42. CP13 stops after `cpu_bootstrap()`; it was RAM-booted and
  Android again reported `shutdown` with an empty pstore. This confirms
  `cpu_bootstrap()` returned. CP42 SHA-256:
  `89c5ec9d96cb49e0f9d32900c7db2d4d3bc09330d947e9c644d19a4649ff1074`.
  CP13 SHA-256:
  `2572074e50e6014a1d62de2b30468fdc5fb60db078853033a8712d60cbad4557`.
- CP14 stops after `rtclock_early_init()`. It passed host checks and was
  accepted by Fastboot; USB disappeared 12.457 seconds later. The phone stayed
  off for about 14 minutes (no Android boot completed between 20:25:16 and
  20:42:07 in `persist.sys.boot.reason.history`, so no watchdog reboot
  happened). The read after power-on was NOT the usual one:
  `ro.boot.bootreason=reboot,asicgood,00,pmic,main`, and `/sys/fs/pstore`
  held one file, `console-ramoops-0`, which is only the bootloader's own log of
  that boot (`No kernel logs` header, `RST_STAT: 0x0 - Cold Reset`, reboot
  reason `0x201 - ASIC_GOOD 00 (Main-PMIC)`, mode normal); it has no watchdog
  reason, panic or crash record. A first power-on at about 20:40:40 appears to
  have been cut short (the Android kernel only started at 20:42:05), probably
  by the held Power button; a second forced reset would replace a `shutdown`
  reason. That is a hypothesis, not observed. CP14 has no direct `shutdown`
  confirmation of its own; it is covered by the CP15 result, which runs
  through it. SHA-256:
  `51f6721384dd871736e7ef37fd55186691fce1be52cccb33506805662aba093e`.
- CP15 stops after `kernel_startup_bootstrap()`. It was RAM-booted at 20:45:49
  with a 4-minute passive USB/ADB watch afterwards; USB disappeared 12.470
  seconds later. Android was back at 20:46:52 (kernel start about 20:46:44) and
  reported `ro.boot.bootreason=shutdown` with an empty pstore, and no watchdog
  or panic record. What restarted the phone was not observed (probably the user
  holding Power). This confirms `kernel_startup_bootstrap()` returned, and since
  CP15 follows CP14 in straight-line code in `arm_init()`, that
  `rtclock_early_init()` returned as well. CP15 SHA-256:
  `31663999a3e99d58b80b315803572b0d8eab9758f0bf20302cd6ebe44a49dd4c`.
- CP16 (after `cpu_init()`), CP17 (after `arm_vm_init()`), CP18 (after
  `serial_init()`), CP19 (after `kernel_startup_initialize_upto(STARTUP_SUB_KPRINTF)`),
  CP20 (after `PE_create_console()`) and CP21 (end of early `arm_init()`, right
  before `machine_startup()`) were each RAM-booted with `fastboot boot` only.
  Every run: Fastboot accepted the image, USB disappeared 12.46-12.48 seconds
  later, and Android came back after the user powered on. Every readout was
  `ro.boot.bootreason=shutdown`, an empty `/sys/fs/pstore`, no watchdog or panic
  record, and the boot history showed one new completed boot per run. All six
  are confirmed. CP21 means early `arm_init()` ran to its end on the 16 KiB-page
  build, including `arm_vm_init()` with the guessed `0x880000000+0x180000000`
  RAM window, `PE_init_platform(TRUE)`, `cpu_timebase_init`, the `/chosen`
  `dram-base`/`dram-size` lookups and `early_random`. It does not say anything
  about `machine_startup()` or later. SHA-256 values are in
  `../outputs/cubs-xnu-checkpoints-2026-10-23/BUILD_NOTES.md`; all images are
  stored there. CP16
  `c60260683614d54247bf8a03fc3fe97ac630b78e0fe00545aa3b1d139faf999f`, CP17
  `88fe39ae73992702370fa2cf2f28d7c4b3d479e6478a30a4277fc1463b20c8bd`, CP18
  `3729d3bf075b250a0b5ba2340c9e08f712811c6193460a56fdaa5a6d7c011f1e`, CP19
  `fa1e788e58ca4a102d46a6e3730a94f1fd3f803a30026460aa0c10e64f71dc11`, CP20
  `0911ca86a6947b4c8e02ccb09ccc069fa1dba665ddada1cf4803407076b00b8f`, CP21
  `a84cab418ca8dea568912257cfd993e38b04aac82d27507133fc53e25828df55`.
- A Mac-side `out/checkpoints/ram_boot_with_watch.sh` wraps the existing runner
  and then logs every ADB/Fastboot/USB state change, so a watchdog return can be
  told from a manual power-on. Across CP15-CP21 Android returned between about
  55 and 190 seconds after launch (CP18 about 103 s, CP19 about 190 s, the rest
  55-67 s); the cause of each restart was not observed, and the spread suggests
  the user's own power-on timing rather than a fixed watchdog delay, but that
  is an inference. `arm_init.c` has no checkpoint after CP21.

## Post-CP21: kernel_bootstrap and kernel_bootstrap_thread (2026-10-23, evening)

- Added 45 new `loader_checkpoint(N)` calls to the Mac XNU tree: CP49 after
  `machine_conf()` in `machine_startup()` (`osfmk/arm64/machine_routines.c`),
  CP50-CP69 through `kernel_bootstrap()` and CP70-CP93 through
  `kernel_bootstrap_thread()` (`osfmk/kern/startup.c`), each right after an
  unconditional call. Applied by `~/unixnu-pixel11/cubs-xnu-bootstrap/out/apply_post_cp21_checkpoints.py`
  (aborts unless each anchor line is unique; originals in
  `out/source-backups/post-cp21/`; a first attempt with the extern in the wrong
  `#if` block was restored from `out/source-backups/post-cp21.attempt1-restored/`
  before the second, correct run). The kernel was rebuilt incrementally
  (`./xnu-build.sh -j8 -k`, 3 s, ends with the usual harmless `check_all_exports`
  error). `llvm-objdump` shows 68 calls to `loader_checkpoint` (23 before + 45).
  The previous kernel is kept as `out/mach.development.bcm2837-before-post-cp21`
  (SHA-256 `5d7b761272d2a8164ba715fa65ec9b5b85879c46bcabc98b80ad2daaa426cc82`)
  with its `.unstripped` symbols beside it. The shim's range check in
  `direct-xnu-checkpoint10/loader.c` and the builder's checkpoint whitelist now
  accept 0..99 (originals saved as `*.pre-post-cp21`).
- RAM-only results on the new kernel, same method as before:
  - CP70 (entry of `kernel_bootstrap_thread()`), CP82 (after `PE_init_iokit()`),
    CP88 (after `OSKextRemoveKextBootstrap()`), CP91 (after
    `vm_set_restrictions()`): each `shutdown`, empty pstore. That is: all of
    `machine_startup()` and `kernel_bootstrap()` (VM bootstrap, scheduler,
    clock, task/thread init), the first context switch, `PE_init_iokit()`,
    `spllo()`, `initialize_screen`, the startup stages through LOCKDOWN,
    `machine_lockdown()` and `PE_lockdown_iokit()` ran.
  - CP92 (after `bsd_init()`) was NOT reached. Android came back by itself
    about 45 s after launch with nobody touching the phone and reported
    `ro.boot.bootreason=kernel_panic,early`, and `/sys/fs/pstore/console-ramoops-0`
    (54,529 bytes) was present. It contains only bootloader logs from the
    previous and the new boot, not XNU output. The new boot's metadata says:
    `RST_STAT 0x3 - Fatal Error SW`, reboot reason `0xbab9 - Early Kernel PANIC`,
    APC WDT sub reason `0xcbea`, and the GDMC trace shows "Crash Reset: Watchdog
    prep trigger" followed by a warm reset. Register/scan dumps are not
    available (PRODUCTION part: scandump disabled, "APC regdump is not
    available"), and "linux debug info is not valid". Fastboot's USB
    disappearance came at 12.877 s instead of the usual 12.46-12.52 s.
  - Reading: the kernel reached CP91 and then hung or spun inside `bsd_init()`
    until the CPU watchdog fired roughly 28 s after XNU started. That `0xbab9`
    is set by the firmware's crash-reset path rather than by XNU is an
    inference; it also does not distinguish a panic spin from a plain hang.
  - Image SHA-256 (built from the rebuilt kernel): CP70
    `0e332dfa4d1b30991c96488bc11c0397d8e5090402c9fb37f53f2570bf81d58e`, CP82
    `f996ea396d42e9b72b8b73f63142c7f25c4cfaa69bfcefa267bcf0f0a82456b5`, CP88
    `d706049b2b0e90a3a75e4d018d689289006eea90a15f388f4fe2fd4a52d25a9b`, CP91
    `ba340fc16dcbef80ad64a94c2729bf717c1be6fd2e0205177186ed0beba9691f`, CP92
    `181bfea233b8cff1b2b28bea9b089dff0fb57ad6918bc8256f784887054ffd91`.
- CP92 is also the negative control the earlier runs lacked: the same method
  produced a clearly different signature (self-return, `kernel_panic,early`,
  non-empty pstore) when the checkpoint was not reached.
- Next: bisect inside `bsd_init()` (`bsd/kern/bsd_init.c`) with new checkpoints,
  then fix whatever it is waiting for (likely a missing root device or
  storage; not yet established).
- Both are `fastboot boot` RAM-only diagnostics. They contain no CUBS display,
  UFS, or iOS root integration and do not constitute a bootable iOS build.

## RAM-only CUBS handoff probes (2026-10-23)

- The watchdog-stop probe was sent with a Mac-side USB timing watcher. Fastboot
  accepted it; USB disappeared 0.763 seconds after launch and returned at
  2.761 seconds. The user reported Fastboot Mode. That is shorter than the
  probe's requested five-second timer delay if the bootloader exposes the
  Android-reported 999.99 MHz architected counter. The Fastboot handoff's
  `CNTFRQ_EL0` remains unmeasured, so entry and watchdog behavior are unknown.
- A minimal PSCI power-off image, with no MMIO or timer access, was first sent
  in a small generated boot wrapper. Fastboot USB returned after 2.744 seconds
  and the user observed Fastboot Mode; this did not confirm payload execution.
- To isolate wrapper differences, the same kernel was inserted into the
  verified 64 MiB stock `boot_a.img`, preserving its full header (OS version 0,
  zero ramdisk) and all other bytes except the kernel-size field and kernel
  span. `fastboot boot` accepted it. Fastboot stayed enumerated through 1.866
  seconds, disappeared at 12.867 seconds, and stayed absent through the
  20-second capture. The user saw a black or powered-off screen. This is strong
  evidence the stock-header image reached a PSCI power-off path; the roughly
  11-second delay is unexplained. It implicates the small generated wrapper or
  ramdisk as a likely contributor to the earlier Fastboot returns, without
  isolating the exact header difference.
- These were temporary RAM boots; no Android partition was written. Use the
  stock boot image as the base for subsequent probes. The FDT and CurrentEL
  probes below provide early handoff markers; the EL2-to-EL1 probe below
  exercises the transition and tests the FDT header again from EL1.
- After the user powered the phone back on, it showed the unlocked-bootloader
  warning and entered stock Android. A read-only ADB check reported
  `ro.boot.bootreason=shutdown`, an empty `/sys/fs/pstore`, and the Android
  physical architected timer at `999.99MHz`. The shutdown reason independently
  corroborates the FDT probe's power-off outcome. The probe checked the
  incoming `x0` pointer for 8-byte alignment, FDT magic, and a plausible header
  size before calling `SYSTEM_OFF`; its failure/exception path calls
  `SYSTEM_RESET`. This is strong evidence that Fastboot supplied a valid FDT
  header in `x0`, but it does not validate the full tree. A subsequent
  CurrentEL probe mapped EL2 to `SYSTEM_OFF` and EL1/exceptions to
  `SYSTEM_RESET`; the screen went black/off and Android again reported
  `ro.boot.bootreason=shutdown`. This strongly indicates the Fastboot entry EL
  is EL2. Details are in
  `../outputs/cubs-fdt-system-off-probe-2026-10-23/` and
  `../outputs/cubs-entry-el-probe-2026-10-23/`.
- A stock-header probe then performed the Bluejay-style EL2-to-EL1 transition,
  confirmed `CurrentEL==EL1`, rechecked the FDT header there, and requested
  `SYSTEM_OFF` from EL1. The phone again reached black/off; after the user
  powered it on, read-only ADB reported `ro.boot.bootreason=shutdown` and an
  empty pstore. This supports a successful EL2-to-EL1 transition and valid FDT
  header access at EL1. It does not prove the complete FDT or every transition
  control is suitable for XNU. Details are in
  `../outputs/cubs-el2-to-el1-fdt-probe-2026-10-23/`.
- Built a RAM-only full-FDT probe using the existing bounded validator at EL1.
  All nine host vectors passed, and the same code accepted a fresh 714,804-byte
  Android FDT (version 17). The 36 KiB Image passed the no-relocation and
  no-undefined checks, and the legacy-LZ4 round trip and stock-header package
  checks passed. See `../outputs/cubs-full-fdt-probe-2026-10-23/`.
- Fastboot accepted the 64 MiB stock-header probe. USB disappeared 12.359
  seconds after launch and stayed absent through 45 seconds; the user confirmed
  the screen is black/off. After power-on, read-only ADB confirmed the same
  `cubs` device, `ro.boot.bootreason=shutdown`, and an empty pstore. This strongly
  supports that the complete Fastboot FDT passed validation at EL1 and the
  probe reached its PSCI `SYSTEM_OFF` success path. No partition was changed.

## Bluejay boot-path update and new diagnostic package (2026-10-22)

- Inspected the `dristotle/ios-bluejay` source at branch `bluejay-port`, tree
  commit `770236a7ab8ea14101304e50b06d6fa54c49d52c`. Its direct path is an
  Android boot v4 image launched with temporary `fastboot boot`, with a shim
  and embedded XNU payload. This means a CUBS UEFI port is not a prerequisite
  if CUBS can use the same Android boot-image handoff.
- Bluejay's loader resolves Mach-O chained fixups in the host packer, places
  XNU segments, ADT and boot arguments in device RAM, and jumps to XNU. Its
  EL2-to-EL1 transition, GS101 MMIO, framebuffer, timer, memory and UFS
  settings are board-specific and must not be copied to CUBS.
- Inspected the local Pixel 11 stock `boot_a.img` with MagiskBoot. Its kernel
  section is legacy LZ4. After decompression, its ARM64 Image header has
  `text_offset=0`, `flags=0xa`, and the `ARM\x64` magic, matching the CUBS
  diagnostic header. The CUBS diagnostic's previous package used a raw
  kernel, so a stock-compression variant was prepared. Bluejay's shim uses
  `text_offset=0x80000`; keep the Pixel 11 value at zero.
- Built `outputs/cubs-diag-stock-lz4-v4-2026-10-22/cubs-diag-boot-v4-lz4.img`
  from the existing UART/FDT diagnostic. MagiskBoot legacy-LZ4 round-trip,
  byte equality, header preservation, Android v4 layout and padding checks
  all passed. Artifact SHA-256:
  `efe095f802c7168938919207cff27d792d6399689af29275ee8c363812ffd290`.
  Full inputs and outputs are recorded in its `BUILD_NOTES.md`.
- This remains only a diagnostic. It has not been booted. The diagnostic
  UART is only confirmed in Android's live FDT; Fastboot's entry FDT and EL
  remain unknown. The Mac at `<lan-ip>` did not answer TCP port 22 from
  this Windows session, and the Windows ADB server failed to start, so no
  device state or new boot result was obtained. No Android partition changed.
- Added `CUBS_BLUEJAY_BOOT_PATH.md` and
  `tools/pack_cubs_lz4_bootv4.py` to preserve the source findings and repeat
  the verified stock-format diagnostic packaging.

## Latest user observation after RAM-only probe (2026-10-22)

- The user did not watch the Pixel during the last temporary boot. It was later back in Android; therefore the screen provided no entry, reset, or crash signal. Treat the PSCI reset probe as inconclusive and do not repeat it.
- The test was RAM-only. The active Android slot and all device partitions remain unchanged.
- SSH to the Mac at `<lan-ip>` is working again. I confirmed the existing HackiOS CUBS profile is explicitly draft-only and preserved all of its uncommitted changes.
- Copied the generic iOS 16.5 `root.apfs`, `system.apfs`, and `rc.jobs.apfs` into `../outputs/ios165-generic-apfs/`. Local and Mac source hashes match. Both the HackiOS Python APFS reader and the separately built XNU C APFS reader completed full reads of root (77 entries) and system (62,356 entries, 5,709,391,787 logical content bytes). `apfsck` is unavailable on the Mac, so its `CHECK=1` validation is still pending.
- The immediate engineering gap remains a CUBS-specific UEFI/boot path and a runtime-qualified XNU 8796 kernel. There is no honest bootable iOS package to offer yet.

## Fresh live CUBS map and source audit (2026-10-22 23:25 EDT)

- ADB is authorized on the Mac; the Pixel is running Android 17 and the root ADB shell reports UID 0. Captured `/sys/firmware/fdt` and `/proc/iomem` read-only to `$HOME/unixnu-pixel11/cubs-live-2026-10-22/`, outside Git. The FDT is 714,804 bytes, SHA-256 `6c9cd93cce0ee5eb02bde8d01f22d3b0fcfa2edce787c899600df96eb2325032`; `/proc/iomem` SHA-256 is `d12336ef8d1879cf679e3b8fecff97e2ee608330d3465bee477b147fae90e228`. The raw tree contains device-specific runtime data and stays private/outside Git.
- Confirmed from this current capture: six 2 GiB RAM banks at `0x80000000`, `0x880000000`, `0x900000000`, `0x980000000`, `0xa00000000`, and `0xa80000000`; seven CPU nodes with MPIDRs `0x000`–`0x600`; capacity groups CPU0/1=`0x30b`, CPU2–5=`0x30c`, CPU6=`0x400`; PSCI `method="smc"`; GICD `0x09228000`; GICR `0x092a8000`; UFS controller `0x3c2d0000`; panel `google-dcsdb`, `1080x2424@120`.
- The Android FDT has no `simple-framebuffer` node and does not give a verified GOP framebuffer address. Its runtime memory map does not establish safe pre-OS UEFI FD or XNU payload ranges. Those fields remain unset in the CUBS profile. The draft loader platform now carries only observed GIC/CPU/PSCI values and a low SoC MMIO window bounded below 1 GiB; it remains unregistered and unbootable.
- Read-only audits of the local Mac trees found no CUBS/Tensor target in Mu-Silicium and no CUBS machine/platform config in the XNU 8796 checkout. Xcode 27's IIG is incompatible with this XNU generation, and the Mac has no KDK. No CUBS UEFI or runtime-qualified XNU can be built from the current trees.

## Public CUBS boot-path search refresh (2026-10-22)

- A current public CUBS AOSP product effort (`PowerPhone/pixel_aosp_manifest`, revision `4664b65e3a1c955bc409c9b8ffd41d67ca4589dd`) documents real-hardware Android 17 boots using Google's stock CUBS boot chain. It can help track current board build inputs, but it is an Android product project and supplies no CUBS UEFI, XNU BootShim, or alternate-OS handoff.
- Google's Generic Bootloader overview says GBL is Android boot logic that runs with UEFI protocol handlers, while Android-specific AVB/Fastboot/slot protocol implementations come from silicon-vendor firmware projects. A generic AArch64 GBL EFI application therefore does not fill the missing CUBS firmware/protocol integration.
- This search did not find a public CUBS/Tensor G6 EDK2 or Mu-Silicium board package. The Pixel 6 Raven/Bluejay EDK2 port and Snapdragon/Sheng firmware remain non-transferable references.
- Sources: [PowerPhone CUBS AOSP manifest](https://github.com/PowerPhone/pixel_aosp_manifest/tree/4664b65e3a1c955bc409c9b8ffd41d67ca4589dd), [AOSP GBL overview](https://source.android.com/docs/core/architecture/bootloader/generic-bootloader), [AOSP GBL source README](https://android.googlesource.com/platform/bootable/libbootloader/+/refs/heads/main/gbl/README.md).

## Boot-image packaging audit (2026-10-22)

- Compared the saved stock `boot_a.img` against the latest reset and UART boot-v4 packages. Their 4 KiB Android v4 header pages match byte-for-byte except the kernel-size field at offset `0x08`; the v4 header is 1584 bytes and uses a 4096-byte page. Header layout/offsets do not explain the Fastboot behavior.
- Stock `boot_a` contains an LZ4 legacy-frame kernel, while the latest probes contain raw ARM64 Images. A separate earlier diagnostic was also tried as LZ4 without a confirmed entry marker, so compression is not established as the cause. The exact bootloader handoff, entry exception level, x0 FDT, and companion-DTB composition remain unknown.
- This audit is host-only. The most recent reset-only attempt remains inconclusive because the user did not observe the screen and no UART capture exists. Do not repeat it without a different observable signal.

## Latest ADB authorization check (2026-10-22)

- USB debugging is enabled and the Mac is authorized. ADB sees the Pixel 11 as `cubs`; `adb shell id` reports root in the KernelSU context.
- The read-only refresh is in `../outputs/cubs-live-devicetree-2026-10-22-android-06/`. Its 714,804-byte FDT and 23,590-byte `/proc/iomem` are byte-identical to capture 05, so the board map has not changed. No reboot or partition write was performed.
- SSH to the Mac timed out during a follow-up artifact check. The existing diagnostic output is present on the Mac, but this turn has not yet re-verified or copied that output.
- The live DTS shows `/aliases/serial0` targeting `uart@3bdd6000`, which is disabled, while `/aliases/serial1` targets `uart@da24000`, which is enabled and marked `google,uart-logging`. The staged diagnostic now targets `0x0da24000` and documents that Fastboot's handoff FDT and physical UART route remain unverified. This revision has not yet been rebuilt or booted.

## Latest verified ADB capture (2026-10-22)

- SSH to the Mac succeeded with the existing task-local key. The Pixel was running Android 17 (`google/cubs/cubs:17/CD1A.260905.001.B1/16238327`) and authorized root ADB through KernelSU. No reboot or partition write was performed during this capture.
- Fresh root ADB files are in `../outputs/cubs-live-devicetree-2026-10-22-android-05/`. The live FDT is 714,804 bytes (SHA-256 `fdb26a80cc0fd9580f1724b773dc05b325eca4711ed75631288562f9259ad40a`); `/proc/iomem` is 23,590 bytes (SHA-256 `d12336ef8d1879cf679e3b8fecff97e2ee608330d3465bee477b147fae90e228`). The memory map matches the prior capture. Decompiling and diffing the FDT shows the same hardware topology; the observed changes are the Secretkeeper public key and UFS PHY calibration values, which are device-specific.
- The live FDT has no `stdout-path`; alias `serial0` points to explicitly disabled `uart@3bdd6000`, while `serial1` points to `uart@da24000` (`goog,goog-dw-apb-uart`, `reg-shift=2`, `reg-io-width=4`). The current diagnostic still hardcodes `0x3bdd6000` from the vendor boot DTB. This is a plausible cause of missing UART output, but the Fastboot handoff FDT and physical UART path remain unverified.
- Read-only partition inspection found `rdbl` at `/dev/block/sdd5` (524,288 bytes) and `blenv` at `/dev/block/sdd3` (8,192 bytes). `blenv` is all zeroes. `rdbl` contains Google DBL/Fastboot firmware strings; a byte scan found no `MZ`, PI `_FVH`, or `BOOTAA64` marker. This is not proof that no UEFI code exists, and it does not establish a CUBS UEFI boot path. No partition was written, erased, or flashed.
- The `UniXNU-cubs` 49 MiB kernel remains the unrelated iPadOS 17 / BCM2837 candidate (`runtime_qualified=false`, `register_dataflow_qualified=false`, native UFS disabled). The iOS 16 / XNU 8796 CUBS platform, boot loader, and runtime-qualified kernel are still missing. The Mac became unreachable during a later diagnostic rebuild attempt, so no build result was produced.

Status: generic iOS 16.5 APFS root/system images have been built and host-parsed, and CUBS-only Android diagnostic packages exist. There is still no CUBS UEFI package, runtime-qualified CUBS kernel, or bootable iOS package. The Pixel is currently booted to Android 17 and accessible over authorized root ADB from the Mac; a read-only Mac Fastboot check confirms `unlocked: yes`, `secure: yes`, slot `a`, and classic Fastboot (`is-userspace: no`). No image was booted and no partition was written in this check.


## Latest connection and bootloader verification (2026-10-22)

- USB debugging is enabled; the Mac's ADB session is authorized and sees serial `<adb-serial>` as `product:cubs model:Pixel_11`. The device shell reports root through KernelSU.
- A read-only Fastboot check confirms `product:cubs`, `unlocked: yes`, `secure: yes`, `current-slot: a`, and `is-userspace: no`. `fastboot reboot` returned the phone to Android; ADB reconnected.
- The fresh verification capture is `../outputs/cubs-live-devicetree-2026-10-22-android-04/`. Its raw FDT and `/proc/iomem` hashes match `android-03`; normalized DTS also matches byte-for-byte.
- This confirms that temporary RAM-boot experiments can be launched from classic Fastboot. The diagnostic Image is not a CUBS kernel or a bootable iOS package; UEFI, verified firmware memory/GOP handoff, and a runtime-qualified CUBS XNU are still missing. No partitions have been written.

## Firmware and kernel candidate audit (2026-10-22)

- A read-only scan of the Mac's Mu-Silicium platform DSC/FDF/INF/DEC/shell files found no CUBS, Malibu, or Tensor G6 platform target. The only firmware-volume file outside per-device driver binaries is the existing `prebuilt/uefi/SILICIUM_UEFI.fd`; no CUBS or Malibu `.fd` image exists in the checked project tree. The Redwood/Snapdragon firmware cannot stand in for a Tensor G6 port.
- The separate `UniXNU/out-cubs/cubs/kernel/kernel.macho` is a 49 MiB ARM64 Mach-O with SHA-256 `b7eea60964c7fb86e0b22018bbe162380123ac61ef63c395771d45c983cece2e`. It comes from a different experimental kernel tree and is not a runtime-qualified HackiOS/XNU 8796 kernel or a bootable iOS package.
- Updated the local platform review draft with the CPU capacity groups and clarified that the Android FDT's 24.576 MHz oscillator is not evidence of the architected timer frequency. The draft remains uncompiled and disconnected from the boot path.

## Public CUBS board-reference source

- Found CUBS device-tree sources in the public `Reeky-ux/lineage_kernel_google_kodiak` repository at revision `188b1a271525545f55579e6180b67f5673cd6186`. Its `malibu-cubs-display.dtsi` names `google,gs-dcsdb`, allowed DSI rates 756/740, and the panel supply rails; these agree with the live Android tree and display logs. See [display DTS](https://github.com/Reeky-ux/lineage_kernel_google_kodiak/blob/188b1a271525545f55579e6180b67f5673cd6186/devices/google/spacecraft/dts/malibu-cubs-display.dtsi) and [common DTS](https://github.com/Reeky-ux/lineage_kernel_google_kodiak/blob/188b1a271525545f55579e6180b67f5673cd6186/devices/google/spacecraft/dts/malibu-cubs-common.dtsi).
- This is a kernel device-tree reference, not a UEFI port. The files are marked GPL-2.0-only; they are being used to confirm board facts, not copied into the EDK2 tree.
- SSH to the Mac timed out twice during a read-only scan of the remaining `rdbl` and `blenv` boot-chain partitions. Those partitions remain unaudited; the device itself is still on Android and the previously collected ADB/Fastboot results are saved locally.

## Latest session update (2026-10-22, later)

- A fresh root ADB capture is at `../outputs/cubs-live-devicetree-2026-10-22-android-02/`. The live FDT is byte-identical to the earlier capture (714,804 bytes; SHA-256 `1fa6de836c11f1d6a0f6033169f0ff8cad872d461251cf20530477da01c179c7`). The 420 `/proc/iomem` lines are text-identical to the first capture; the hashes differ because `adb exec-out` preserved LF line endings instead of the earlier shell/PowerShell CRLF conversion. Current raw-file hash is `d12336ef8d1879cf679e3b8fecff97e2ee608330d3465bee477b147fae90e228`.
- While Android was connected, `ro.boot.flash.locked=1` and `ro.boot.vbmeta.device_state=locked`. This conflicts with the earlier Fastboot `unlocked: yes` observation from 2026-10-21. `adb reboot bootloader` was issued to verify the bootloader's own read-only `getvar` values, but Windows `fastboot devices -l` stayed empty, so those variables were not obtained. The user now confirms the screen says Fastboot Mode; the USB host still does not enumerate a Google/Android interface. Do not infer unlock status from either Android properties or the earlier Fastboot snapshot.
- Pulled active `abl_a` read-only (8 MiB; SHA-256 `cf3cf79b2dc8a97e3a02b5f8c3c3300736405a3b9273e996588600d742593474`). Its strings identify Android `abl/lk/` and `abl/gsp/` components. Structural scanning found no PE/COFF image or UEFI PI `_FVH` signature; official UEFIExtract NE A75 exited with parser error 39. This active ABL is not a standard UEFI volume from which to extract Redwood-style DXE drivers. This does not rule out other boot-chain firmware sources.
- A new ASCII/UTF-16 string scan of the same ABL found no literal `GBL`, `UEFI`, `BOOTAA64`, or `android_esp` strings. This is only a string-scan result and does not establish whether LK implements the UEFI protocols required by GBL.
- `uefi/apply.sh` completed on the Mac and cloned Mu-Silicium at pinned commit `e51cd877e31c8fbb322032dc4cb6715e83d25ad3`, including its submodules. The tree has no Google/Tensor/CUBS package. The existing Redwood package is Qualcomm-specific and its fixed memory/peripheral map is not reusable for Malibu.
- A second read-only audit of `references/edk2-tensor` found only Pixel 6-era Raven/Bluejay packages. Its 4 GiB map, 24.576 MHz timer, GIC bases `0x10400000`/`0x10440000`, and Raven RAM-dump boot script are not CUBS values or a safe CUBS boot path; that tree's own ACPI map conflicts with its platform map.
- Built and host-verified the CUBS diagnostic package on the Mac. Local copies are `../outputs/cubs-diag-Image-2026-10-22.bin` (22,656 bytes; SHA-256 `34068b65c38f1cdd4208460246fc1057972f7bc5adda7a165c0e85ad51528818`) and `../outputs/cubs-diag-boot-v4-2026-10-22.img` (28,672 bytes; SHA-256 `2a83bbe6b2e1c124b18a2bab0f296efd78a5c4acd01cef6ec9b3bc7d063fc150`). Nine native FDT vectors passed; ARM64 Image header, v4 header/layout, no-ramdisk/no-signature properties, embedded Image bytes, and hashes passed. This is a diagnostic probe, not an iOS image, and it has not been booted in this session.
- Removed the staging build script's reference to absent `tools/inspect_android_v4.py`; the package's own `verify_image.py` performs the checks above. The fail-closed guard in `mkxnuimg.py` remains in place. No Android partition was written.

## Generic Bootloader (GBL) route check (2026-10-22)

- Google's Android GBL documentation describes GBL as a UEFI application. The documented deployment requires firmware that already provides the required UEFI/Android protocols, AVB integration, slot handling, memory services, and `android_esp_a`/`android_esp_b` FAT partitions; LK can be used only with the required firmware modifications. GBL is therefore not itself a UEFI firmware port. [AOSP: Deploy GBL](https://source.android.com/docs/core/architecture/bootloader/generic-bootloader/gbl-dev)
- The active `abl_a` scan found no PE/COFF image or PI firmware-volume signature, but that alone does not prove the boot firmware lacks UEFI protocols. The refreshed `android-04` inventory contains no `android_esp_a/b`; the observed `esp_a/b` are still the separate 4 MiB blank partitions. No GBL image or UEFI boot integration has been identified.
- The draft `common/devices/cubs.conf` previously said the phone boots a Mu-Silicium UEFI via `fastboot boot`. I changed that comment on the Mac to mark this as an unverified proposal until the actual Pixel boot chain is shown to launch a CUBS UEFI image.
- Historical snapshot: Windows could not enumerate the device in Fastboot. The current Mac session now sees ADB and Fastboot; current read-only values are recorded above.

The original HackiOS repositories have now been reviewed and cloned as references. Their iOS 16.5 / XNU 8796.121.2 baseline matches the project the user asked about, but their phone port is Snapdragon/Redwood-specific; there is no CUBS or Tensor G6 port in those trees. A read-only Android DTFS capture and the newer raw FDT plus `/proc/iomem` capture provide concrete CUBS CPU, PSCI, GIC, UFS, GPU, display, touchscreen, and memory facts. The current FDT is still an Android runtime tree, not a proven drop-in UEFI boot DTB.

## Latest live capture (2026-10-22)

- ADB now lists serial `<adb-serial>` as `device product:cubs model:Pixel_11`; `adb shell id` returned `uid=0(root)` with KernelSU context `u:r:ksu:s0`.
- Running build identity: Android 17 `CD1A.260905.001.B1`, bootloader `spacecraft-17.4-16238327`, Linux `6.12.69-android16-6-g5c5f2fea42dd-ab15835541-4k`.
- Read-only captures are in `../outputs/cubs-live-devicetree-2026-10-22-android-01/`. The raw `/sys/firmware/fdt` is 714,804 bytes, SHA-256 `1fa6de836c11f1d6a0f6033169f0ff8cad872d461251cf20530477da01c179c7`; `/proc/iomem` has 420 lines, SHA-256 `d3d88efad2cde79d639adf8401f5b3c6af62bc151caaa43c8fca0fa2a3965dba`.
- The FDT confirms six 2 GiB RAM banks: a low bank at `0x80000000-0x100000000` and an adjacent upper 10 GiB span at `0x880000000-0xb00000000`. Current Android `/proc/iomem` reports the largest interval outside its `reserved` subranges as `0x880000000-0xabbf49000` (8.937 GiB). That is promising for HackiOS's 6 GiB cap, but does not prove a UEFI conventional-memory allocation is available.
- CPUs `0-6` are online. Android does not expose `ID_AA64MMFR0_EL1` at the queried sysfs path, so the Tensor G6 physical-address range is still unconfirmed. Full analysis is in `HACKIOS_CUBS_MEMORY_REVIEW.md`.
- The Mac's `vendor_kernel_boot_a.img` was copied read-only and SHA-256 checked. Its two embedded DTBs are `google,mbu`, each with only 256 MiB RAM; neither matches the live `google,malibu-cubs` FDT. The runtime overlay/memory expansion source remains unresolved.
- The Mac-side `hackios-upstream` CUBS profile still has blank UEFI and load addresses, and there is no `Mu-Silicium/Build` target output. Its pre-existing uncommitted CUBS draft files were preserved. I added a fail-closed check to `mkxnuimg.py`: non-Redwood targets now require their matching firmware, BootShim, DTB, ramdisk, mkbootimg, and explicit load addresses. Running the current CUBS profile now exits before producing an image; the check passed and left no output file. This is only a guard, not a CUBS implementation.
- The Pixel's Android partitions remain untouched. No flash, erase, or partition write occurred during this capture.

The earlier device and inventory notes below are snapshots from before root ADB reconnected; current device facts are recorded above.

## End-of-night checkpoint (2026-10-21)

- Latest reconnect attempt after the user woke the Mac: TCP port 22 at `<lan-ip>` briefly answered, but SSH login failed with `Permission denied`; this Windows session has no running `ssh-agent`. A retry with the task's local private key timed out, so Mac reachability is still intermittent and no remote build/status command completed. Do not overwrite or reset any Mac-side files; inspect its current working tree before resuming.
- Offline source checkpoint on Windows: `ios-cubs-port/xnu-8796.141.3` is the exact Apple XNU `xnu-8796.141.3` base at commit `1b191cb58250d0705d8a51287127505aa4bc0789`, with SWEET patches 0001-0081 applied locally (uncommitted). The pinned Apple HFS source is at `ios-cubs-port/build_inputs/hfs-627.100.6`, commit `31d5ec238dfab485e78a9a30b8b92d13e8914f03`. This is patched source preparation only; it is not a CUBS kernel build.
- The Pixel was last observed in bootloader Fastboot. Android partitions remain untouched; no flash, erase, or partition write has occurred.
- The correct phone OS baseline is iPhone X iOS 16.7.16 (20H392), using public XNU `xnu-8796.141.3`. On the Mac, `$HOME/unixnu-pixel11/xnu-8796.141.3-cubs-build` is a SWEET source-control baseline with staging inputs and patches 0001-0081 applied. It has no CUBS machine/platform implementation and no successful CUBS kernel build. The separate `xnu-8796.141.3-cubs` scratch clone is partially patched; do not use it as the clean baseline.
- The `cubs-xnu-prototype-main94-20261021` work is based on a newer XNU generation and failed its configuration/build attempts. The previously produced UniXNU `DEVELOPMENT_ARM64_BCM2837` kernel is also not a Pixel kernel.
- Build blockers on the Mac: Xcode 27 Beta 3 is installed, no KDK is installed, the XNU 8796 workflow calls for Xcode 15-era IIG, and GitHub CLI authentication is invalid. Public CI run `39158169212` provided buildtree artifact `12147962438` (SHA-256 `543d1a49ac334ebfc509573a0933fc93dd27744ae29464eca7c8c3f3a2985d21`, expires 2026-10-25) and kernel artifact `12147422947`; extracted path `$HOME/unixnu-pixel11/github-xnu-buildtree-39158169212/tree`. Its `sdk-kernel-platform` directory is empty, so private KDK headers are still missing.
- RAM-only Fastboot probes included the delayed PSCI reset sentinel and UART/FDT diagnostic variants. The phone disconnected/reappeared over USB and returned to Fastboot. No UART output or captured screen confirms `CUBS:ENTRY` or `CUBS:FDT_OK`; treat diagnostic execution/FDT parsing as unverified. Do not infer successful kernel entry from USB resets.
- Mac SSH at `<lan-ip>` timed out on the final retries. A checkpoint was inserted into the Mac checkout's `NOTES.md`, but the companion `docs/cubs-porting.md` update could not complete and no documentation commit was made. Preserve Mac-side uncommitted edits to `shim/cubs/start.S` and `shim/cubs/verify_image.py`.
- Next: establish reliable SSH authentication to the awake Mac, inspect both Mac checkout status and the existing CUBS-profile Mach-O candidate before changing files, then update `docs/cubs-porting.md`, find a compatible XNU 8796 build environment, implement the CUBS-specific machine/platform/loader path, and continue with evidence-captured RAM-only boots. Keep partitions untouched.

## Current CUBS milestone (2026-10-21)

- The iPhone X GSM/CDMA iOS 16.7.16 (20H392) restore's OS, SystemOS, and AppOS DMGs were downloaded to the Mac's internal disk, CRC-verified, and mounted read-only. No iOS root image has been assembled.
- A CUBS-only ARM64 diagnostic kernel and Android boot v4 package were built on the Mac outside Git and committed as source under `shim/cubs/` in the Mac checkout. Host validation passed nine FDT parser vectors, AArch64 ELF checks (no undefined symbols/runtime relocations), ARM64 Image checks, and boot v4 layout/kernel equality checks.
- Copies are at `outputs/cubs-diagnostic-2026-10-21/Image` (22,656 bytes; SHA-256 `ae16fe5272a2f48b57608df54e9a85ec5c866dae3f21a8a96160584bc932b565`) and `outputs/cubs-diagnostic-2026-10-21/cubs-diag-boot-v4.img` (28,672 bytes; SHA-256 `33e519065c5cc24038c42fa6dc6b14c3eed61eba3ea9c46f1126111ab2d2e765`). The image is a UART diagnostic probe, not iOS.
- Elevated Fastboot confirms the connected device reports `product: cubs`, `unlocked: yes`, `current-slot: a`, and `is-userspace: no` (bootloader Fastboot). The standard unelevated Fastboot process cannot open the Google WinUSB interface (Win32 access denied). An initial temporary boot from fastbootd (`is-userspace: yes`) returned `Unrecognized command boot`; after switching to bootloader Fastboot, the diagnostic package transferred and the command returned `OKAY`, but the phone remained in Fastboot and showed no observed diagnostic execution. A saved stock `boot_a.img` then booted Android successfully from RAM; ADB confirmed device `cubs`, build `google/cubs/cubs:17/CD1A.260905.001.B1/16238327:user/release-keys`, slot `_a`. The phone was returned to bootloader Fastboot. No flash, erase, or partition write was sent.
- A follow-up local header audit found a plausible diagnostic boot defect. The stock `boot_a.img` kernel payload is an LZ4 legacy frame; after decompression, its ARM64 Image header has `code0=0xFA405A4D` (EFI/MZ signature/no-op), `code1=0x14847819` (AArch64 branch), `text_offset=0`, `image_size=0x28E0000`, `flags=0xA`, and magic `0x644D5241`. The original diagnostic Image had a valid branch at `code0=0x14000010` but zero at `code1`. A code1 branch to the shim entry at offset `0x40` was added to a one-word image/package variant and independently host-verified; the ARM64 boot protocol defines both header words as executable code used to reach `stext` (EFI entry skips them initially).
- The exact code1-branch v4 package (`100be9df8f30397092cf11656b83b449b57ce219d7f50424fd4864a45f0897a0`) was temporarily submitted with `fastboot boot`; Fastboot returned `OKAY`, but the device remained enumerated as Fastboot and the user confirmed the screen stayed on Fastboot Mode. ADB showed no device. The code1 fix alone did not verify execution. The Mac-side source/build/commit status is still unconfirmed, and no partition write occurred.
- A canonical non-EFI NOP-plus-branch header variant was made from the same diagnostic payload: `code0=0xD503201F`, `code1=0x1400000F` branching to offset `0x40`. Its raw v4 package SHA-256 is `2a83bbe6b2e1c124b18a2bab0f296efd78a5c4acd01cef6ec9b3bc7d063fc150`; its source Image SHA-256 is `34068b65c38f1cdd4208460246fc1057972f7bc5adda7a165c0e85ad51528818`. A legacy-LZ4-wrapped kernel was also built; decompression reproduced the same Image hash, and the LZ4 v4 package SHA-256 is `e950d2540bde449916e59d637db5169d5580ff65c72cccd0f80e4c429ba53290`. Both packages passed host structure checks and `fastboot boot` returned `OKAY`, but Fastboot remained responsive (`product: cubs`, `is-userspace: no`) and ADB saw no device. The user confirmed Fastboot Mode after both tests; neither format variant has demonstrated shim execution.
- A stale `cubs-patch-stage/verify_image.py` copy expected a branch in `code0`, contrary to the current canonical NOP-plus-branch source. It now checks the current image header, reserved fields, Android boot v4 layout, and embedded-kernel equality. Both the original staging verifier and the corrected staged verifier accept the canonical 22,656-byte Image and 28,672-byte package with the recorded SHA-256 values. This is host artifact verification only and does not change the failed RAM-boot result.
- The Linux arm64 boot protocol confirms `x0` carries the physical DTB pointer and `x1`–`x3` are reserved zero, matching the diagnostic shim's capture of `x0`; the actual FDT pointer/content supplied in the prior Fastboot boot attempts remains unobserved. The protocol also specifies executable `code0`/`code1` words that branch to `stext` ([kernel boot documentation](https://docs.kernel.org/6.18/arch/arm64/booting.html)).
- A 4 KiB PSCI reset sentinel was assembled locally without touching MMIO or FDT: the ARM64 Image masks interrupts, sets PSCI function ID `0x84000009` (`SYSTEM_RESET`), issues `SMC #0`, and waits if the call returns. The package reuses the first 4 KiB of stock `boot_a.img`, changing only its kernel-size field and kernel bytes. The host parser accepted it as boot v4 (header 1584, page 4096, raw 4 KiB kernel, no ramdisk/signature/cmdline). Image SHA-256 is `8face08397f024ab4b49336740bf4edb1f2b8ce5b469f970077a0c6516e22bad`; package SHA-256 is `4cfb659b9fccf73afb7ccc64cc6be6e97871482d5dfbe2b8aac76e86ff2107f6`.
- The reset sentinel was temporarily booted with `fastboot boot`; the bootloader returned `OKAY` in 0.304 seconds. Immediate read-only checks still found serial `<adb-serial>` in Fastboot and no ADB device. This does not distinguish a failed handoff from a fast PSCI reset back to bootloader; user confirmation about whether the screen visibly reset is pending. No partition write, erase, or flash occurred. The screen text reported before this probe was `enter reason: reboot bootloader`.
- A delayed variant was built locally at `outputs/cubs-diagnostic-2026-10-21/psci-reset-probe-delayed/`. It runs a 4,294,967,296-iteration AArch64 decrement loop before requesting PSCI reset. After RAM-booting it, an elevated read-only Fastboot poll saw serial `<adb-serial>` disappear at `23:12:32.211` and reappear at `23:12:34.677`; the user observed the screen back in Fastboot. This timed USB disconnect/re-enumeration is strong evidence the image reached its loop and the PSCI reset call returned the phone to bootloader Fastboot. Image SHA-256 is `b98909727deb8c72967434a589c5040906eaf6d2b2b52eff828617d6896eb5fc`; v4 package SHA-256 is `8c202ab8b0bba84fe39e6f6aff7448ced65eae67e117ca5aca7aa6c1a0d21301`. No partition write, erase, or flash occurred.
- The canonical NOP-plus-branch UART/FDT diagnostic package passed `verify_image.py` (Image SHA-256 `34068b65c38f1cdd4208460246fc1057972f7bc5adda7a165c0e85ad51528818`, v4 package SHA-256 `2a83bbe6b2e1c124b18a2bab0f296efd78a5c4acd01cef6ec9b3bc7d063fc150`) and was temporarily booted. Fastboot disappeared at `23:13:42.928` and reappeared at `23:13:45.360`. Since this payload is intended to wait after UART/FDT reporting, the return may be a boot watchdog reset; no UART output was captured, so FDT handling remains unverified. No partition write occurred.
- The Fastboot symptom now has a plausible structural explanation: Pixel 7+ devices split kernel artifacts across `boot`, `vendor_boot`, and `vendor_kernel_boot`; Android's generic ramdisk is also in `init_boot`. The diagnostic v4 image contains only a kernel and no companion images. Google documents these partition roles, but does not specify whether CUBS bootloader `fastboot boot` automatically composes its active-slot companion images for an arbitrary downloaded image. The DTB's PSCI conduit and the exact handoff state remain unknown. See [Google's Pixel kernel guide](https://source.android.com/docs/setup/build/building-pixel-kernels), [Android vendor boot documentation](https://source.android.com/docs/core/architecture/partitions/vendor-boot-partitions), and [Android generic boot documentation](https://source.android.com/docs/core/architecture/partitions/generic-boot).
- Read-only `fastboot fetch vendor_kernel_boot_a` was denied by the bootloader as a restricted partition; the empty local output created by the failed fetch was removed. This prevented direct local inspection of the active DTB. Mac file `~/unixnu-pixel11/cubs-stock-2026-10-21/vendor_kernel_boot_a.img` contains a separate 64 MiB image, but SSH is currently intermittent. On the Mac checkout, branch `pixel11-cubs-port` has uncommitted edits to `shim/cubs/start.S` and `shim/cubs/verify_image.py`; these latest source edits have not been rebuilt or committed.
- A fresh elevated `fastboot devices -l` check on 2026-10-21 reports serial `<adb-serial>` in bootloader Fastboot. No flash, erase, or partition write was sent during the diagnostic sequence.
- A later local Fastboot/ADB check returned no connected device. The Mac at `<lan-ip>` also timed out on SSH, so neither hardware observation nor the Mac-side kernel build can continue until those connections return.
- The Mac now has a CUBS-profile XNU Mach-O candidate at `~/unixnu-pixel11/UniXNU/out-cubs/cubs/kernel/kernel.macho` (49 MiB, ARM64). Its metadata explicitly says `runtime_qualified: false`; its config disables native UFS, and it is not yet evidence of a CUBS-bootable kernel. The iOS root image and end-to-end CUBS boot package are not yet confirmed. SSH became unreachable again before the package target and remaining build logs could be inspected.

## Device facts read from the connected phone

Read-only ADB queries on 2026-10-20 reported:

- Product device: `cubs`
- Model: `CUBS MP based on MALIBU`
- Device-tree compatible values: `google,malibu-cubs`, `google,malibu`
- SoC property: `Tensor G6`
- Android build: `google/cubs/cubs:17/CD1A.260905.001.B1/16238327:user/release-keys`
- Kernel: `6.12.69-android16-6-g5c5f2fea42dd-ab15835541-4k`
- ABI: `arm64-v8a`
- Boot storage property: `3c2d0000.ufs`
- Fastboot verification: product `cubs`, bootloader unlocked (`unlocked: yes`), active slot `a`
- Android boot properties separately reported `ro.boot.flash.locked=1`, `vbmeta.device_state=locked`, verified boot green, slot `_a`; those lock values conflict with Fastboot and are treated as unreliable for this build
- Bootloader version: `spacecraft-17.4-16238327`

No phone partitions were written during this audit.

## Porting baseline

- UniXNU's published device list has one supported hardware port: Xiaomi Pad 6S Pro (`sheng`, Qualcomm SM8550). Its graphics work targets Adreno 740.
- UniXNU requires a separate device repository and UEFI firmware port. UEFI, framebuffer, input, block I/O, and filesystem support come before XNU bring-up.
- The public `TAOcroatia/edk2-tensor` repository is a 2023 EDK2 attempt for Pixel 6 Pro (`raven`) and Pixel 6a (`bluejay`), not a Pixel 11 or Tensor G6 port. Its code demonstrates a Linux-kernel `BootShim` plus a `fastboot boot` UEFI-image path, which is a useful packaging reference.
- Further read-only audit: that Tensor reference places a UEFI allocation at `0x880000000`, the same base as CUBS's upper DTFS RAM span, but its README says the map came from Pixel 6 `/proc/iomem` and needs work. Its `tensor.dsc` also defines a separate low-base memory range. Treat the shared high address only as a lead for the CUBS EFI-map investigation. The repo has a Synaptics TCM command/report implementation, but its transport is Qualcomm QUP I2C; CUBS reports `synaptics,tcm-spi`, so the transport and controller setup would need a separate SPI implementation. Its Raven run script issues vendor `fastboot oem ramdump` commands and is not suitable to run unchanged on CUBS.
- Further read-only audit: that Tensor reference places a UEFI allocation at `0x880000000`, the same base as CUBS's upper DTFS RAM span, but its README says the map came from Pixel 6 `/proc/iomem` and needs work. Treat it only as a lead for the CUBS EFI-map investigation. It also has a Synaptics TCM command/report implementation, but its transport is Qualcomm QUP I2C; CUBS reports `synaptics,tcm-spi`, so the transport and controller setup would need a separate SPI implementation. Its Raven run script issues vendor `fastboot oem ramdump` commands and is not suitable to run unchanged on CUBS.
- I found no existing UniXNU or EDK2 board port for `cubs` / `malibu`.
- The live device tree exposes a large SoC-specific peripheral map. The current UniXNU native GPU code is Adreno-specific, so the Pixel 11 GPU and Metal path would require new work.

## HackiOS source review and CUBS applicability (2026-10-22)

- Public reference checkouts: `references/hackios-xnu-kernel` at `8e61187098f2c26c5daee8f9f72b6416aa64b9ab`; `references/hackios-xnu-userland` at `906425b75e02b4f99eb5d7bb1ef7c9583472d772`. Both are clean source checkouts.
- This is the original HackiOS project the user meant. Its XNU base is Apple `xnu-8796.121.2` (iOS 16.5 / Darwin 22.5.0); its userland instructions extract iOS 16.5 from an Apple IPSW and create `root.apfs` and `system.apfs`. It claims successful bring-up on POCO X5 Pro 5G (Snapdragon 778G) and QEMU.
- The strongest reusable pieces are a Linux-based XNU build path, XNU changes for PSCI SMP/GICv3 and basic framebuffer display, APFS/ramfs, the loader's Apple boot-args/ADT construction, and a DTB-driven starter platform profile. These are useful as the 16.5 implementation base, but need auditing and adaptation to the CUBS boot ABI.
- The porting guide explicitly requires a per-device Mu-Silicium UEFI port, UEFI drivers extracted from that phone's XBL, new memory-map/boot-shim addresses, and device-specific platform values. Redwood framebuffer values, UFS path, Qualcomm power, and XBL binaries must not be carried over to CUBS. Its `FD_BASE=0x9FD00000`, `FD_SIZE=0x200000`, and `PAYLOAD_BASE=0xF0000000` happen to fall in gaps in the Android DTFS's fixed reservations, but remain unverified candidates until the CUBS UEFI `GetMemoryMap` is measured.
- CUBS live DTFS confirms 7 PSCI-enabled CPUs with MPIDRs `0x0..0x600` in `0x100` steps and PSCI `smc`; GICv3 distributor `0x09228000` and redistributor `0x092a8000`; UFS controller `0x3c2d0000`; and three capacity classes (779, 780, 1024). HackiOS's generator only records the minimum-capacity mask (`0x3`) and assumes simple clusters, so a CUBS scheduler/topology mapping still needs explicit design.
- The live tree identifies the touchscreen as `synaptics,tcm-spi` at `/spi@da2c000/touchscreen@0`, unlike HackiOS Redwood's Goodix GT9916. It identifies the GPU as `google,mbu-gpu` / `img,gpu`, unlike Redwood Adreno 642L. Both require new drivers for a usable UI/graphics path; no CUBS Metal-capable driver is present in HackiOS.
- Serial-console audit: `/aliases/serial0` points to `/uart@3bdd6000`, a `goog,goog-dw-apb-uart` with `reg-shift=2`, `reg-io-width=4`, and `status=disabled`. `/aliases/serial1` points to `/uart@da24000`, the same UART type with `status=okay`; `/chosen/stdout-path` is absent and Android bootargs specify `console=null`. HackiOS's current platform UART field expects PL011, so neither address can be used by simply filling `.uart`; the enabled UART is a possible debug lead after adding/validating DesignWare APB access, clocks, and pin mux. The platform draft keeps `.uart=0`.
- A recent public Fuchsia DesignWare APB UART driver includes the exact `goog,goog-dw-apb-uart` compatible and declares `baudclk`, `apb_pclk`, reset, and power-domain dependencies ([driver change](https://fuchsia.googlesource.com/fuchsia/%2B/637a4b51c1861541d15cb5b099860e61a040e349%5E%21/)). This is a register/bring-up reference only; it does not prove CUBS exposes a usable serial header or provide an XNU/UEFI driver.
- `tools/inspect_android_dtfs.py` and the generated `hardware-inventory.json` now retain UART aliases, enabled state, register shift/width, clock and pinctrl names, plus `/chosen` bootargs/stdout properties. This makes the lack of a confirmed console explicit; it does not establish that the serial pins are externally accessible.
- Generated inventory: `../outputs/cubs-live-devicetree-2026-10-22/hardware-inventory.json`; its source tree is `../outputs/cubs-live-devicetree-2026-10-22/base`. The sysfs DTFS copy loses the raw FDT header/reservation map; the boot UEFI still needs the original DTB or a justified replacement.
- Starter C initializer with only the currently verified platform fields is at `build_inputs/HACKIOS_CUBS_PLATFORM_DRAFT.c`. It deliberately leaves the SoC peripheral window and GOP framebuffer unknown and must not be used to build or boot yet.
- Memory review: `HACKIOS_CUBS_MEMORY_REVIEW.md` compares HackiOS's contiguous EFI window allocator to the CUBS DTFS. The captured tree describes a 10 GiB contiguous high-memory span; HackiOS's XNU window is capped at 6 GiB. Exact XNU 8796.121.2 uses a default 40-bit translation range, which covers this 34–44 GiB span at the software level. The Tensor CPU's `PARange` and actual EFI memory map remain unverified.
- Baseline direction: continue the HackiOS/iOS 16.5 code path for fidelity to the original experiment. Keep the already prepared iOS 16.7.16/XNU 8796.141.3 sources as a separate fallback/reference; they are not a substitute for the HackiOS 16.5 port and need not be the chosen build baseline.
- Next technical blockers, in order: recover the original active-slot raw DTB/vendor_kernel_boot input; inventory CUBS boot-firmware drivers and memory map; port a CUBS boot path; build the HackiOS loader/kernel against CUBS facts; then bring up Synaptics touch and display. Keep the Android install intact: package iOS APFS images as host-side artifacts and load them into RAM over the loader's USB/Fastboot path. Do not flash, erase, repartition, or write to userdata. The existing HackiOS UFS write path must remain disabled for CUBS.

## Earlier device and inventory checkpoint (2026-10-22, before root ADB reconnected)

- The saved stock `boot_a.img` was validated as an Android boot v4 image and temporarily booted with Fastboot RAM boot. ADB confirmed the target as `cubs`; Android's `/sys/firmware/fdt` was root-only and `su` was unavailable, so the raw FDT could not be copied.
- `adb pull /sys/firmware/devicetree/base` succeeded and produced the captured DTFS inventory. It is sufficient to read the hardware properties above, but does not retain the binary FDT header or reservation map. No Fastboot flash, erase, or partition write occurred.
- The inventory script now records CUBS's `synaptics,tcm-spi` touchscreen node. The generated JSON's `buildable: false` flag is intentional because boot-chain addresses and device drivers remain unresolved.
- The local stock `vendor_boot_a.stock.img` and `vendor_boot_b.stock.img` backups are both Android v4 `VNDRBOOT` images (64 MiB, 2048-byte page, 2128-byte header) with `dtb_size=0`; scanning each full image found no FDT magic. There is no local `vendor_kernel_boot` image. The Mac's previously recorded `~/unixnu-pixel11/cubs-stock-2026-10-21/vendor_kernel_boot_a.img` is the next read-only source to retrieve when SSH works.
- A fresh host check found no Fastboot device, and ADB could not start its local server. No device command ran. SSH to the Mac at `<lan-ip>` timed out on the escalated read-only check; no remote files were touched.
- Latest host recheck: TCP 22 at `<lan-ip>` is unreachable, `fastboot devices -l` is empty, and ADB still fails to start. Windows WSL returns `E_ACCESSDENIED`; Docker, QEMU AArch64, and Clang are absent. No local Linux build route or connected device is currently available.

## Build host status

The available build Mac is Apple silicon running macOS `27.0.1`. Xcode `27.0` Beta 3 is installed at `/Applications/Xcode-27.0.0-Beta.3.app`; setting `DEVELOPER_DIR` to that app exposes the iPhoneOS `27.0` SDK. The Mac's system-wide developer directory remains Command Line Tools, so the build shell must export `DEVELOPER_DIR` or select the Xcode app before using `xcodebuild`.

The Mac has Python `3.14.8`, Git `2.55.0`, GNU Make `3.81`, Homebrew, and `226 GiB` free. Homebrew has CMake `4.4.3`, Ninja `1.13.2`, unifdef `2.12`, LLVM `23.1.3_2`, mtools `4.0.49`, dtc `1.8.1`, and LLD `23.1.3`; the user verified the required executables resolve. Homebrew keeps LLVM, LLD, and unifdef keg-only, so the shell PATH must include `/opt/homebrew/opt/llvm/bin`, `/opt/homebrew/opt/lld/bin`, and `/opt/homebrew/opt/unifdef/bin`. The build shell must also export `DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.3.app`. The Windows workspace still cannot run the complete kernel build; the Mac is the build host.

The Mac has `UniXNU`, `UniXNU-sheng`, `uefi-sheng`, and a separate `UniXNU-cubs` device tree under `~/unixnu-pixel11`. Earlier `sheng` reference builds completed and helped stage Apple headers. The CUBS-targeted profile now produced an ARM64 Mach-O at `UniXNU/out-cubs/cubs/kernel/kernel.macho`; the saved config is a generic XNU baseline with `CONFIG_XNU_NATIVE_UFS` disabled, and kernel metadata marks it `runtime_qualified: false`. The output package and build command state have not yet been inspected. No complete, runtime-qualified CUBS kernel or iOS root image has been confirmed.

## Practical milestones

1. Assemble a clean `cubs` device and UEFI source tree, using only confirmed board values and clearly marked unknowns.
2. Build a diagnostic UEFI boot image on a supported build host, then use a temporary fastboot boot for the first screen/menu check.
3. Adapt the UniXNU kernel and Apple device-tree generator for Tensor G6; first aim for kernel entry and logs, without mounting or writing userdata.
4. Bring up UFS, display, touch, and power. A usable Metal renderer would need a separate driver for the Pixel 11 GPU.
5. Build the iOS 16.5 APFS images on the host and deliver them to the loader for a RAM-only boot. Keep Android userdata and all Android partitions intact. If the root image cannot fit in the verified RAM window, stop and redesign the RAM-loading path rather than writing it to UFS.

## Source checkouts

The public reference checkouts are under `references/`: `UniXNU`, `UniXNU-sheng`, `uefi-sheng`, `ios-sweet`, `edk2-tensor`, `hackios-xnu-kernel`, and `hackios-xnu-userland`. Device images, serial numbers, and personal data are not stored in these repositories.



## Sleep checkpoint (2026-10-22)

See SLEEP_CHECKPOINT_2026-10-22.md for the full verified state and next actions. The Mac at <lan-ip> was reachable over SSH, although a later poll timed out. The HackiOS userland fetch completed and both generic iOS 16.5 APFS images were produced. No CUBS kernel/UEFI image is ready, and no CUBS boot has been verified. Android partitions remain untouched.

Last successful Mac check at 2026-10-22 21:00 EDT: `root.apfs` is 4,194,304 bytes, `system.apfs` is 2,492,203,008 bytes, and `rc.jobs.apfs` is 754 bytes. SHA-256: root `dffb588c498321b7800e9d285feb570938a7819db0c2a442da8a9389e2159c8a`; system `8d27af4e95bb4dcb887d4034058b63fc298fc7125222b4599e3509a46c53cc0f`; rc.jobs `a8350028467d23b5720a420979a1ae1c4a46de764adc7681fb6cd07858c0095e`. HackiOS's Python APFS reader parsed both containers: `root.apfs` reports 59 files, 17 directories, one symlink, 7 checksums verified and 0 bad; `system.apfs` reports 45,138 files, 16,547 directories, 671 symlinks, 12,331 checksums verified and 0 bad. A stronger `apfsck` check remains pending: the pinned Linux APFS checker does not build on macOS as-is because its Linux UAPI headers (`linux/types.h`) are missing. No Pixel-targeted UEFI/kernel exists yet. Details and compatibility edits are in SLEEP_CHECKPOINT_2026-10-22.md.

### Mac Fastboot connection confirmed (2026-10-22)

- With the Pixel in Fastboot Mode, the Mac USB tree enumerated Google Pixel 11 (VID `0x18d1`, PID `0x4ee0`).
- Homebrew already had Android platform-tools installed; the minimal SSH PATH omitted them, so `/opt/homebrew/bin/fastboot` was used directly.
- `fastboot devices -l` returned serial `<adb-serial>` on USB. Read-only variables returned product `cubs`, `unlocked: yes`, `secure: yes`, current slot `a`, and bootloader `spacecraft-17.4-16238327`.
- No image was booted and no partition was written during this connection check. Windows still did not enumerate the phone; the Mac is now the working Fastboot host.

### ADB authorized and raw live FDT recaptured (2026-10-22)

- The user enabled USB debugging on the Pixel and authorized the Mac. `/opt/homebrew/bin/adb devices -l` reports `<adb-serial> device product:cubs model:Pixel_11`; `adb shell id` reports root in KernelSU context.
- Read-only captures of `/sys/firmware/fdt` and `/proc/iomem` plus build identity were copied from the Mac into `../outputs/cubs-live-devicetree-2026-10-22-android-03/`. The raw FDT is 714,804 bytes (SHA-256 `b5e763f7d9caaed045fcde1de048498a9c51d19611c382e7114d6fa47daeb6bf`); `/proc/iomem` is 23,590 bytes (SHA-256 `d12336ef8d1879cf679e3b8fecff97e2ee608330d3465bee477b147fae90e228`).
- Normalized `dtc` output differs from capture 01 only in the AVF Secretkeeper public key and UFS PHY calibration data. The six-bank memory map and relevant hardware topology are unchanged. These boot/runtime fields are not copied into the board profile.
- The HackiOS userland has generic iOS 16.5 `root.apfs` and `system.apfs` images. The CUBS device profile is still explicitly draft-only: its DTB field now points to the raw live Android FDT for hardware inventory, but that tree contains runtime properties and is not validated as a pre-OS boot DTB; UEFI FD and load addresses remain blank, and no CUBS UEFI FD or complete iOS boot package exists. A 49 MiB UniXNU Mach-O candidate exists but is marked `runtime_qualified: false`.
- No command wrote to a Pixel partition. Next build milestone is a CUBS-specific UEFI/loader diagnostic that can report the live GOP and `GetMemoryMap`; Android's FDT and `/proc/iomem` do not safely select firmware load addresses.
- A read-only `/dev/block/by-name` inventory is saved with capture 03. It exposes `dbl_a/b`, `abl_a/b`, `bl31_a/b`, and `esp_a/b`, but no `xbl` or `uefi` name. The two ESP partitions are 4 MiB each and were pulled read-only; both are entirely zero-filled. A private local copy of the 512 KiB `dbl_a` image has Google DBL/Fastboot strings and ABL/BL31 loading messages, with no PE/COFF or UEFI FV signature markers. This confirms the Snapdragon guide's XBL binary/driver recipe cannot be applied as written; it does not prove there are no EFI-capable components elsewhere in proprietary firmware.
- AOSP's [GBL deployment requirements](https://source.android.com/docs/core/architecture/bootloader/generic-bootloader/gbl-dev) call for UEFI protocol support and two FAT `android_esp_a/b` partitions of at least 8 MiB. CUBS's observed `esp_a/b` links are 4 MiB and blank, so the standard GBL deployment path is not present in this layout.
- The Android display stack exposes DRM but no `/sys/class/graphics` fbdev interface or physical framebuffer address. `card0-DSI-1` is connected/enabled at 1080×2424@60/120; `dmesg` identifies `panel-gs-dcsdb` on `f7d8000.dsi2host`, with DSI link rates around 740–756 Mbps. See `display-readout.txt` in capture 03. This confirms panel topology, not a bootloader GOP buffer. Keep `.fb_base` unknown; a display-capable iOS boot needs a CUBS GOP or DPU/DSI/panel implementation.
- Do not populate ESP or flash any partition as part of this Android-preserving, RAM-only goal. The immediate boot-chain gap remains a CUBS-specific UEFI/loader that can execute from the fastboot-booted shim.

### RAM diagnostic boot attempt (2026-10-22)

- The new Android live FDT says `/aliases/serial1` points to the enabled `goog,goog-dw-apb-uart` at `0x0da24000` (`reg-shift=2`, `reg-io-width=4`); `/aliases/serial0` points to disabled `0x3bdd6000`. The diagnostic was rebuilt to poll the enabled live-tree UART's LSR and write only its THR, with bounded polling and exception-vector reporting. The Fastboot handoff FDT and physical UART routing remain unverified.
- Host build completed with nine native FDT parser vectors, ARM64 ELF checks (no undefined symbols or runtime relocations), Image header checks, Android boot v4 package checks, and an independent image verifier. The Image is 22,656 bytes (`0c8cb19f3410bb1168f43ba5ac779dfdabb28b67c3470c352aa76a30ffb2df6a`); the 28,672-byte boot v4 image is `aaae34d37806ad81af9b9d92e8b72d9cb70a78891b494e0f7a85683a5957fc04`. Build output and artifacts are in `../outputs/cubs-diag-enabled-uart-2026-10-22/`.
- Fastboot read-only variables confirmed `product=cubs`, `unlocked=yes`, and `is-userspace=no`. `fastboot boot` accepted the RAM image (`Sending boot.img OKAY`, `Booting OKAY`), but four seconds later the phone still enumerated as Fastboot; no ADB, UART capture, or on-screen kernel marker proved entry into the diagnostic. `fastboot reboot` returned the phone to Android 17; root ADB subsequently reappeared. Slot remained `_a`, pstore was empty, and no partition write/erase/flash occurred.
- This attempt is inconclusive, not a kernel-entry milestone. Do not repeat the same image. The next diagnostic should resolve the actual incoming FDT's console/UART (rather than assume the Android runtime FDT's UART), or use a separately validated visual indicator after the handoff framebuffer is identified. The incoming FDT, firmware memory map, and GOP remain unmeasured.

### PSCI entry probe (2026-10-22)

- Built a separate 20,480-byte ARM64 Image / 24,576-byte Android boot v4 package. After the common ARM64 Image entry setup reaches C, it makes no board MMIO accesses and invokes PSCI `SYSTEM_RESET` through the SMC conduit declared by the live tree. Independent local package verification passed. Image SHA-256: `7eb1ebf879eaf52d4f53654d580179a35615474b11748e31601f428086601c6f`; boot image SHA-256: `941aac0173ef11dca7ec051540ff59e21e09452506bbd9a6669321bd08d3ad92`. Artifacts and build source are in `../outputs/cubs-reset-probe-2026-10-22/` and `../cubs-shim-staging/`.
- `fastboot boot` accepted the image. The phone remained enumerated in Fastboot for 20 seconds, so the test did not provide a positive kernel-entry signal; a reset could also return to the bootloader's Fastboot screen. `fastboot reboot` restored Android 17 and root ADB on slot `_a`. No partition write, erase, or flash occurred.
- This does not establish whether the image entry ran or whether PSCI SMC was honored. Stop repeating reset-only probes; next obtain an observable entry marker tied to actual handoff state (for example, parsed UART/FDT or a validated display signal) before another RAM boot.

## 2026-10-23 Bluejay-shape diagnostic attempt

- Prepared and byte-verified a CUBS diagnostic package using Bluejay's Android v4 + legacy-LZ4 + empty gzip/newc ramdisk format. See `outputs/cubs-diag-bluejay-shape-2026-10-23/BUILD_NOTES.md`.
- Temporarily submitted it with `fastboot boot` only. Fastboot returned OKAY, remained responsive, and the user confirmed the screen stayed in Fastboot Mode. No flash, erase, or partition write occurred; this is not a boot success.
- The static DTBs extracted from `vendor_kernel_boot_a.img` report `serial0=0x3bdd6000` and `serial1=0xda24000` disabled, unlike the captured Android runtime FDT, where `uart@da24000` is enabled. The current CUBS diagnostic hardcodes the latter. Resolve actual Fastboot FDT/entry EL and UART routing next.

## 2026-10-23 Bluejay entry-path probe

- Compared `dristotle/ios-bluejay` source with the CUBS shim. Bluejay's README reports an iOS 16.7.16 lock-screen boot on Pixel 6a / GS101 using a temporary Android boot v4 + legacy-LZ4 shim. Its EL2 entry explicitly enables EL1 timer access, clears `CNTVOFF_EL2`, sets `HCR_EL2.RW` and a known EL1 `SCTLR_EL1`, then `eret`s to EL1. Bluejay also page-aligns the final Image and embedded payload. CUBS keeps its own stock `text_offset=0`; the local Pixel 11 kernel header says zero, while Bluejay uses `0x80000`.
- Built a separate page-aligned CUBS reset probe that ports the EL2-to-EL1 transition, preserves the original entry EL, waits a distinct loop count for EL2 vs EL1, then requests PSCI `SYSTEM_RESET`. Source is isolated under `../cubs-shim-staging/bluejay-el1-prototype/`; Mac repository edits were not overwritten.
- Host verification passed ARM64 header/branch checks, no-relocation/no-undefined checks, legacy-LZ4 round-trip, Android boot v4 section/layout checks, and empty-newc validation. Artifacts: `../outputs/cubs-bluejay-el1-reset-probe-2026-10-23/`; boot SHA-256 `3de27cce31d13a89039c6f0b7fc24a5d54a7e32486cf51a432fa8da769495b1f`.
- Before boot, Mac Fastboot reported `product=cubs`, `unlocked=yes`, `is-userspace=no`. `fastboot boot` returned OKAY. The host observed Fastboot USB present at epoch `1792789578.054`, absent at `1792789578.467`, and present again at `1792789580.325`; read-only queries again reported `product=cubs`, `is-userspace=no`. This is consistent with the image or firmware entering a reset path, but it does not prove the EL2-to-EL1 code ran or identify the original EL. No partition write, erase, or flash occurred.
- No CUBS XNU target or UFS implementation exists in the current `ios-sweet-cubs` checkout. The Bluejay README's tested XNU build uses macOS 14 / Xcode 15.0.1; the Mac has Xcode 27 beta. GitHub has macOS 14 runner brownouts in progress today, with retirement announced for Nov 2, 2026. A CUBS-specific XNU config/platform/UFS port and a supported build host are still required before a bootable iOS image can be produced.

## 2026-10-23 CUBS timed and hold probes

- The user confirmed the Pixel returned to Fastboot after the reset probe. This is expected after its explicit PSCI reset and does not, by itself, mean the image was rejected.
- Built a separate Bluejay-style EL2-to-EL1 probe that waits 5 seconds for an EL1 entry or 10 seconds for an EL2 entry using `CNTFRQ_EL0`/`CNTPCT_EL0`, then requests PSCI reset. ARM64 header/branch, no-undefined/no-relocation, legacy-LZ4 round-trip, Android boot v4 layout, and empty-newc checks passed. The image is 20,480 bytes; boot image is 12,288 bytes, SHA-256 `2f916e469c8492b5a30b9833aae487c07866ea870c5bc25c9cb5f1c2c1b71fc0`. See `../outputs/cubs-bluejay-el1-timed-reset-probe-2026-10-23/BUILD_NOTES.md`.
- The Mac monitor saw the second USB disconnect at 0.759 seconds and Fastboot return at 2.604 seconds; the device stayed in Fastboot through the remainder of the 35-second window. The elapsed 1.845 seconds is shorter than either requested counter delay, so the expected delay was not observed.
- Built a second probe whose normal C path parks indefinitely in `WFE`, while its exception handler requests PSCI reset. Packaging checks passed. Its boot image SHA-256 is `124e53df469034ec16e9d33d5335ec68f14e8444be9aeb190718e2018b7c336c`; details are in `../outputs/cubs-bluejay-el1-hold-probe-2026-10-23/BUILD_NOTES.md`.
- Fastboot USB returned 1.873 seconds after the second disconnect and remained available through the 40-second window. The hold loop was not observed; an exception-path reset, firmware reset, or early boot rejection are still possible. Read-only Fastboot variables again reported `product=cubs`, `unlocked=yes`, and `is-userspace=no`.
- No Pixel partition was flashed, erased, or written. These probes have no positive EL1, FDT, UART, framebuffer, or XNU-entry marker and do not count as boot milestones.

## 2026-10-23 Android timer and post-probe readout

- After a safe `fastboot reboot`, root ADB again sees the stock Android 17
  system on serial `<adb-serial>`; Fastboot is currently not active.
- Read-only Android `dmesg` reports `arch_timer: cp15 timer(s) running at
  999.99MHz (phys)`. `/proc/timer_list` reports the architected counter's
  conversion multiplier as `16777190` with shift `24`, consistent with that
  frequency. The previous timed shim's 5/10-second wait was therefore not
  observed in the host USB trace; a zero or slow counter is less likely, but
  this Android log does not directly prove the shim's `CNTFRQ_EL0` read.
- `/sys/fs/pstore` is empty and Android reports `ro.boot.bootreason=reboot`.
  There is no retained panic record or specific reset cause from the temporary
  probes.
- The saved stock `boot_a.img` SHA-256 on Windows and the Mac is identical:
  `8e4c29a524adfe1e0ee7ae554bc04e90d36a2c79f69b5c88c0be836dbdc6d972`.
  This remains a known-good RAM-boot control; no partition writes were made.

## 2026-10-23 Pixel 11 source cross-check

- [iOS Bluejay](https://github.com/dristotle/ios-bluejay) reports reaching the iOS 16.7.16 lock screen with touchscreen input on Pixel 6a / GS101. Its boot format and shim are useful references; its GS101 UFS, RAM map, display, touch and CPU parameters do not transfer to CUBS/Tensor G6.
- The checked public `kernel/devices/google/p11` main revision was empty; its populated 5.15 branch is Qualcomm SW5100. [Espada Kernel](https://github.com/atrejokm301/espada-kernel) claims Pixel 11 family support and testing on `grizzly`, but the reviewed tracked tree contained no CUBS/`malibu`/DC9x00 board support or XNU port. Neither source provides CUBS-ready XNU platform code.
- The saved Android live FDT identifies `google,malibu-cubs`, Google UFS, Verisilicon DC9x00 display, Google DCSDB panel, GICv3 and seven CPU nodes. These remain runtime Android facts, not a validated Fastboot handoff map.
- Next boot-chain milestone is a trustworthy observable signal for the exact Fastboot handoff (entry EL and x0 FDT) before writing further board-specific hardware code. The full CUBS XNU platform/UFS port and a working iOS boot package remain unfinished.

## 2026-10-23 vendor watchdog audit

- The user reported that the minimal branch-to-WFE entry sentinel still left
  the Pixel in Fastboot Mode. That observation does not distinguish entry from
  early rejection, firmware reset, or a watchdog reset.
- Read-only inspection of the stock `vendor_kernel_boot_a.img` found the same
  two `google,wdt` nodes in its DTB and the live Android FDT. The matching
  `google_wdt.ko` exposes its stop sequence: unlock with `0x00c0ffee`, program
  the timeout count, clear control bit 0, then relock with 0. The DT clock is
  38.4 MHz, with configured Android timeouts of 24 and 30 seconds. Those Linux
  timeout values are a poor match for the approximately two-second USB
  re-enumerations; pre-OS watchdog behavior remains unknown.
- Built a temporary probe from the vendor values. It stops both watchdogs,
  waits five seconds via `CNTFRQ_EL0`/`CNTPCT_EL0`, and asks PSCI for a system
  reset. ARM64 header/vector placement, no undefined symbols or relocations,
  legacy-LZ4 round-trip, and Android boot v4 package layout passed. See
  `../outputs/cubs-google-wdt-stop-probe-2026-10-23/BUILD_NOTES.md` and
  `../cubs-shim-staging/google-wdt-stop-probe/`.
- The probe has not been run: `fastboot devices -l` is empty on Windows and the
  Mac. It writes only watchdog MMIO during a RAM boot; no Pixel partition has
  been flashed, erased, or written. If its MMIO or timer path faults, the
  exception handler parks and a hardware-forced reboot is needed.

## 2026-10-23 XNU direct-handoff checkpoint run

- The Pixel returned to stock Android after the first XNU direct-handoff
  attempt. Read-only ADB reported `ro.boot.bootreason=watchdog,apc,early`; the
  pstore console records a fatal hardware reset and APC watchdog expiry at
  roughly 74 seconds. This is consistent with an early XNU stall, not a
  specific fault location.
- The HackiOS XNU Mach-O contains one `XNULDRST` loader slot and startup
  checkpoints 1–6. The CUBS shim had not populated the slot. The shim now
  patches it to a no-stack assembly return handler, with checkpoint returns
  issuing PSCI `SYSTEM_OFF` and early exceptions issuing PSCI `SYSTEM_RESET`.
- Checkpoint 1–5 RAM images were built on the Mac and passed the FDT/RAM-window,
  ARM64 Image, legacy-LZ4 round-trip, and stock boot-v4 layout checks. Their
  hashes and build logs are in
  `../outputs/cubs-xnu-bootstrap-2026-10-23/BUILD_NOTES.md`.
- Checkpoint 1 was submitted with `fastboot boot` only. Fastboot accepted the
  64 MiB image. The Pixel disappeared from Fastboot USB at 12.466 seconds and
  remained absent through the 45-second observation. The user later confirmed
  Android returned; the Mac currently sees no ADB device, so the boot reason
  remains unread and the checkpoint is unconfirmed.
- Checkpoint 6 was added immediately before the C `arm_init()` entry. The
  incremental build assembled and linked the updated kernel, then failed in
  the XNU symbol-set import audit. The packaged 64 MiB checkpoint 6 image
  passed the host FDT/RAM-window, ARM64 Image, legacy-LZ4 round-trip, and boot
  v4 layout checks. Its SHA-256 is
  `f13aab79e4ec413cf40773114de615b4f8f0188bef4f5144c758644341fbcbeb`.
  It has not been run on the device. The latest Windows checks find no ADB,
  Fastboot, or Google/Android USB device; SSH to the Mac times out. The
  checkpoint runner has not started.
- No Android partition has been flashed, erased, or written. This is a kernel
  startup diagnostic, not a bootable iOS system: the kernel is still a generic
  BCM2837 build, and the image lacks an iOS root image and CUBS display/UFS
  drivers.
