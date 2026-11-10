# ios-cubs

**An experimental port of iOS 16.5 to the Google Pixel 11 ("cubs"), built on [HackiOS](https://github.com/oosexgang/hackios-xnu-kernel).**

Apple's open-source XNU kernel (`xnu-8796.121.2`, the kernel of iOS 16.5) runs on one CPU core of the phone *beside a live Android*, and the unmodified iOS 16.5 user space (launchd, backboardd, SpringBoard, apps) runs on top of it. Nothing is flashed: the phone boots Android as usual, a script hands one core to XNU, and a reboot always brings the phone back to Android.

The Pixel's own hardware is reused where iOS has no driver for it. Android keeps the GPU, display controller, radios, camera and microphone and serves them to iOS through shared memory (the "bridge" servers in `pixel/`).

> **Status: research prototype.** It boots to the lock screen and home screen and runs apps, but several things are slow or missing (see below). Expect to read logs. Running it can leave the phone in an unusual state until the next reboot; a supervised runner that always returns to Android is included and is the only way this has been tested.

> **No Apple or Google proprietary files are in this repository** — no iOS system image, IPSW, firmware, device trees, boot images or private traces. You supply your own (see [Building](#building-and-running)). This project is independent and is not affiliated with, authorised or endorsed by Apple Inc. or Google LLC. iOS, iPhone and Apple are trademarks of Apple Inc.; Pixel is a trademark of Google LLC.

## Status

| Area | State |
|---|---|
| Boot to lock screen / home screen, swipe to unlock, app launch | Works |
| Touch screen and the three hardware keys | Works (the power key does not wake the screen after sleep yet) |
| Display | Works. Linux DRM scan-out buffers filled by XNU (command-mode panel, DPU commit replayed); brightness follows iOS through a bridge |
| GPU (OpenGL ES) | Works through GL forwarding to the PowerVR (ANGLE on Vulkan): about 10 fps idle, 13–15 fps while swiping. A direct present path that skips the pixel readback is in progress (see [GPU](#gpu)) |
| GPU (Metal) | Metal-to-Vulkan translation (`pixel/gpusrv`, AIR to SPIR-V) runs compute, render, depth and MSAA samples on the PowerVR |
| Safari / web views | Works (WebKit accelerated drawing is switched off by an injected library) |
| Network | Works over a virtual interface bridged to Android's current connection; a view-only Wi-Fi status panel in Settings |
| Sound output | Works (PCM to an Android app) with iOS volume keys |
| Sideloading apps | Works (in-place registration + one SpringBoard restart) |
| USB | The phone shows up to a Mac as an iPhone (usbmux over FunctionFS); pairing/Trust does not complete yet |
| Camera | Frames reach iOS; the viewfinder is black, a permission/hand-off problem is being investigated |
| Microphone | Android capture, shared-memory ring and the kernel device work; iOS apps still receive silence |
| Cellular, calls, SMS, Bluetooth | Not started |

Details, measurements and dead ends are in [`docs/dev-log/`](docs/dev-log/) (long and unpolished by nature).

## How it works

```
 Android (Linux)                                   iOS 16.5 (XNU on CPU 6)
 ───────────────                                   ───────────────────────
 glsrv   GLES on the PowerVR      ◄── ring ──►    libredwood-gl   GL forwarding
 mtlsrv  Metal → Vulkan           ◄── ring ──►    libmtlshim      Metal shim
 sndsrv / micsrv  AudioTrack/AAudio ◄─ ring ──►   /dev/redwood-audio, /dev/redwood-mic
 netsrv  tun device + NAT         ◄── ring ──►    en0 (virtual NIC)
 camsrv  camera frames            ◄── ring ──►    camera device
 persistsrv  storage, brightness  ◄── HTTP ──►    cubs-persist, brightbridge
 DRM scan-out buffers (drmfb)     ◄── RAM ──►     framebuffer blit, DPU commit replay
        shared RAM reserved at PA 0xab2000000
```

* **Dual boot / AMP** – a kernel module (`pixel/handover`, `pixel/kernel-handover`) takes CPU 6 offline from Linux and starts XNU's entry point there with iOS's ARM device tree; the rest of the system keeps running Android.
* **Kernel work** – a patch against Apple's XNU plus new files (`overlay/xnu`), a platform description for the Pixel (`overlay/common/devices/cubs.*`) and the display, touch, GPU and sound glue that is compiled into the kernel (`pixel/xnu/*.inc`).
* **User space** – iOS's user space comes from Apple's IPSW; our injected libraries, launchd job lists and an APFS image builder come from the HackiOS userland project.

### GPU
iOS draws with OpenGL ES calls that `libredwood-gl` forwards through a shared-memory ring to `glsrv` on Android, which executes them on the Pixel's GPU. Today the finished frame is read back and copied into the scan-out buffer by XNU, which costs most of the frame time. A spike (`pixel/gpu`) showed that rendering into a linear `AHardwareBuffer` and page-flipping it through DRM runs at 120 flips/s with about 2.5 ms of GPU time per frame; the integration into `glsrv` (`pixel/glfwd/glpresent.c.inc`, enabled with `GL_PRESENT=1` and the kernel boot arg `cubs_blit=0`) is functional but not yet in production. The plan is in [`docs/design/gpu-rework-plan.md`](docs/design/gpu-rework-plan.md).

## Repository layout

| Path | What |
|---|---|
| `overlay/` | Files that **differ from or are added to** upstream HackiOS, at their upstream paths: the XNU patch and new kernel files, the Pixel platform description, build-script changes. Copy them over an upstream checkout |
| `pixel/` | Our own components: the bridge servers (`glfwd`, `gpusrv`, `gpu`, `mic`, `net`, `usb`, `camapp`, `jb`, `drmfb`), the kernel glue (`xnu`), the CPU hand-over module, and the Mac-side build/run scripts (`mac_scripts`) |
| `tools/` | Python and shell helpers used while bringing the kernel up (patch appliers, probes, image packers) |
| `docs/` | Design notes (`design/`) and the development log (`dev-log/`) |

## Building and running

This repository does not contain the upstream toolchain, kernel base or iOS user space. You need:

1. A checkout of [hackios-xnu-kernel](https://github.com/oosexgang/hackios-xnu-kernel) and [hackios-xnu-userland](https://github.com/oosexgang/hackios-xnu-userland) (both by OOSEX GANG), set up as their READMEs describe, on a Mac or Linux build host.
2. Apple's iOS 16.5 IPSW for your own use (the upstream scripts fetch and extract it on your machine).
3. A **Pixel 11 with an unlocked bootloader and root** (KernelSU was used here) connected over USB. All device-specific addresses in this tree are for that phone.
4. Copy `overlay/` over the upstream kernel checkout, then follow `docs/dev-log/HANDOVER.md` and `IOS_BOOT_CHECKLIST.md` for the build recipes (`pixel/mac_scripts/build_*.sh`) and the supervised runner `pixel/mac_scripts/run_guarded.sh`, which keeps a watchdog on the phone and always restores Android.

The scripts assume a particular directory layout and host; read them before running them, and expect to adapt paths. A clean-machine build has not been verified.

Two kinds of data are deliberately **not** published and must come from your own device: the display-controller register sequence that the kernel replays to refresh the command-mode panel (`osfmk/arm64/cubs_replay.h`, recorded from the Linux display driver on the phone), and the device tree / firmware-derived tables used for bring-up. The capture procedure is described in `docs/dev-log/` (display bring-up).

## Safety

* Always run through the supervised runner. A test that does not end with the phone restarting into Android is a bug.
* Never write to raw block devices by letter (`/dev/block/sdXN` letters shift between boots); use `/dev/block/by-name/...` and check sizes.
* Fastboot, kernel hand-over and display experiments can hang the phone or lose USB until a hard reset. You do this at your own risk.

## Credits and licensing

* **[HackiOS](https://github.com/oosexgang/hackios-xnu-kernel)** by OOSEX GANG is the foundation: the XNU port, EFI loader, replacements for Apple's drivers and the userland. This project is a port of it to a different phone.
* **Apple XNU** ([apple-oss-distributions/xnu](https://github.com/apple-oss-distributions/xnu)) is licensed under the Apple Public Source License 2.0; the files derived from it keep that license (`LICENSE.APSL`).
* The remaining original code in this repository is released under the MIT License (`LICENSE`), unless a file says otherwise. See `NOTICE.md`.
