# STATUS UPDATE 2026-11-08 (Claude, 10-hour autonomous run) — read this first

Production on the phone is now: payload `cubswifi` (production image with Sileo/Procursus prefix, persistence, Wi-Fi status bridge; RAMOFF `28c8000`; boot args `cubs_net=1 cubs_wifi=1 cubs_sound=1 cubs_shot=1 cubs_hb=1 cam=5 cam_fake=1 cam_bridge=1`), flags in `/data/local/ios`: `jb` (loads `system-jb.img`, starts `persistsrv`), `wifi` (WifiStatusService + wifisrv/wifiscansrv), camera flags OFF (`cam`/`camid`/`camdelay` absent: the Android camera streaming during iOS boot freezes XNU at ~62 s about half the time). Backups/rollbacks: `ho.payload.pre-wifi`, `.pre-jb`, `.pre-cam`, `.pre-vol`; `env.sh.pre-wifi/.pre-jb`; `ios_start.pre-wifi2/.pre-jb`; one-line rollbacks are in the header of `pcwork/mac_scripts/inst_wifi.sh` and `inst_jb.sh`.

What works: dual boot, buttons, internet (Wi-Fi or mobile data, event-driven route switch ~4 s), HTTPS (Safari shows the lock; page area black), Sileo (full UI), persistent package store (`pcwork/net/persistsrv.c` + `pcwork/jb/cubs-persist.sh` + `rwhttp`; inbox `/data/local/ios/inbox/*.deb`, `pcwork/jb/ipa2deb.sh`), Settings > Wi-Fi shows the real connected network + nearby networks (view only), sound sink, volume amplitude, battery.
Open: layers owned by another process are black (Safari content, Camera viewfinder, sideloaded app windows): WebContent paints nothing into its IOSurfaces; sideloaded apps register but SpringBoard refuses to open them; camera freeze (needs the black-layer fix to matter); swipes 13-15 fps (analysis in the checklist: ~35 ms GL latency + ~50 ms single-core CPU per frame); calls/SMS not started; Wi-Fi join/power stay disabled.
Tools: `pcwork/mac_scripts/run_guarded.sh` (supervised runner, see its header), `logfix.py` (the kernel log is a wrapping ring), heartbeat page `ringrd 0xFF2000`, shot ring `ringrd 0x1C00000`. Traps: see the 2026-11-08 sections at the end of `IOS_BOOT_CHECKLIST.md` (shell escaping through ssh, RAMOFF per payload, system image reserve 2559852544, `jb` flag vs small-reserve payloads, never PUSH over `system-jb.img`).

# HANDOVER: iOS 16.5 on a Pixel 11 ("cubs") beside live Android

Written 2026-11-04 for another LLM that continues the work until Saturday morning (the previous assistant, Claude, has run out of weekly budget).
Read this file first, then `IOS_BOOT_CHECKLIST.md` (the long dated log of every experiment, newest sections at the end; it is the ground truth for evidence).
Be economical: every experiment ("cycle") costs ~8 minutes of wall time; reading outputs costs tokens, so print little.

---------------------------------------------------------------------------------------------------

## 0. The user, the goal, the rules

* User: the maintainer (<maintainer-email>). Wants these working on the Pixel, **without human intervention unless a big blocker**: buttons, Wi-Fi, cellular, cameras, dual boot (Android <-> iOS), plus smooth GPU-accelerated UI (they complained that swipes feel sluggish; the panel is 120 Hz).
* Style: autonomous, no confirmation prompts ("don't ask, just do"), report faithfully (say what failed, what was not verified). Keep answers short.
* Hard rules:
  1. **The phone must always end in Android.** Every test ends with a reboot into Android (cycle.sh does it). Never leave it in iOS or fastboot unattended.
  2. **Never push to GitHub** without asking (public fork `hesm4tt/ios-cubs` at 8484245; nothing of this work was pushed).
  3. **Keep vendor firmware, device trees, serials, IPSW, boot images, trace files out of any public repo.**
  4. **Never `dd` to raw `/dev/block/sdXNN`** (LUN letters shift; a raw write once hit cpm_a). Flash by name only: `/dev/block/by-name/<partition>` with a size check.
  5. Discord ping (webhook URL is in the first user message of the old Claude session transcript; ask the user for it): only when a *real physical* step is needed (phone dead, replug). Send 10 pings in a minute and every message must contain the mention `<@<discord-user-id>>`. Do not ping for a mere `adb: no devices` right after a reboot: wait 3-5 minutes first (the previous assistant pinged wrongly once).
  6. Commit trailer (if you ever commit, and only if the user asks): `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; PR bodies end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
  7. **End-of-project cleanup is owed** (do it only when the user says the work is finished): flash the stock boot_a back (backup `~/andboot/boot_a.ORIG.img` on the Mac, md5 `f30ee4474721b58ac8cec849a80773d0`) and remove the PC's SSH key (`claude-windows`) from the Mac's `~/.ssh/authorized_keys`. Until then the phone runs the modified boot_a (`boot_resmem_nopkvm.img`: cmdline `reserve_mem=6656M:32M:cubs kvm-arm.mode=none`).

---------------------------------------------------------------------------------------------------

## 1. Hardware / software topology (how it works)

* Phone: Pixel 11 "cubs" (Tensor), **7 CPU cores numbered 0-6** (there is no CPU7! asking the firmware for "cpu7" crashed bl31 and the phone vanished from USB until a power cycle). Android is a recent build (sdk 37). Root through KernelSU.
* iOS = **HackiOS XNU 8796.121.2** (iOS 16.5 20F66, from an iPhone10,3 IPSW) running on **CPU6 beside the live Android** ("AMP"): Linux offlines CPU6 and the module `cubs_stage.ko` starts XNU there with PSCI CPU_ON (entry 0x922004000). Linux keeps owning all hardware; iOS drives some hardware directly (touch SPI, GPIO buttons, DPU commit replay) and gets everything else through **Android-side servers talking over a shared-memory ring**.
* The iOS system image is `/data/local/ios/system.img` (2.49 GB). `ios_start.sh` `cat`s it into RAM at every boot: **changes iOS makes to its disk are lost at reboot** (so deleting caches at boot, e.g. `rmicons`, only affects that boot).
* Shared RAM ring: PA `0xab2000000` (reserved by Linux, attached in `/dev/cubs_ram` with `printf Eab2000000:10000000 > /dev/cubs_go; printf O0 > /dev/cubs_go`). XNU maps it with `io_map(..., VM_WIMG_DEFAULT)` and flushes with `FlushPoC_DcacheRegion`; Android reads/writes it with `pread`/`pwrite` at explicit offsets. Layout (offsets from the span start):

| offset | what |
|---|---|
| 0x000000.. | Metal ring (mtlsrv) |
| 0xE10000 (+0x1000 payload, max 0x1D0000) | OpenGL ES forwarding mailbox (glsrv, GL_OFF) |
| 0xFF0000 | return-to-Android word "BYE1" (0x31455942) |
| 0xFF1000 | wall clock: ASCII "TIME<epoch>\n" written by netsrv; XNU sets its calendar from it |
| 0x1000000 (size 0x81000) | network ring (netsrv <-> `bsd/dev/redwood_cubs_net.c`) |
| 0x1100000.. (frame data at +0x1000, request at +0x800, up to 0xF00000) | camera ring: XNU writes a request "CAMQ"(w,h,bayer,stride), camsrv answers with RAW10 and header "CAMR"(seq,w,h,len). Keep frames < ~9 MB because the audio ring starts at 0x1A00000 |
| 0x1A00000 (size 0x41000) | audio ring (NEW, untested): header magic "AUD1", wr@+0x40, rd@+0x80, ring of 16384 frames at +0x1000 |
| 0x1C00000 (size 0x400000) | kernel screenshot: "SHOT", seq, 540, 1212, BGRA at +0x1000 (quarter size copy of the iOS framebuffer, every ~5 s when boot-arg `cubs_shot=1`) |

* Display: iOS draws into a RAM framebuffer (PA printed in the log as `CUBS blit: fb pa 0xaa1400000 rowbytes 4320 height 2424`; it is Linux-allocated RAM that `/dev/cubs_ram` cannot read, hence the SHOT ring). XNU's blit thread copies bands into Linux DRM scan-out pages (`drmfb2` holds the DRM fd; `fblist.bin` lists the physical runs) and replays the DPU commit sequence (`cubs_blit.c.inc`).
* GPU: backboardd (CoreAnimation render server) uses OpenGL ES (`gl=1`) forwarded through the ring to `glsrv` on Android (EGL/ANGLE on Vulkan on the PowerVR C-Series). Metal goes through a shim (`mtlshim`, `mtlsrv`, metal2vulkan). `libredwood-gl.dylib` is the client library (`pcwork/glfwd`).
* Network: iOS gets a virtual Ethernet `en0` (upstream `redwood_net`); the link driver `bsd/dev/redwood_cubs_net.c` carries frames through the ring to **netsrv** (Android, `pcwork/net/netsrv.c` + `netsrv.sh`): it answers ARP/DHCP (iOS 10.77.0.2, gateway 10.77.0.1, DNS 1.1.1.1/8.8.8.8), passes IPv4 through a tun device `ios0`, and `netsrv.sh` sets forwarding, MASQUERADE and the policy-routing rules Android needs (`iif ios0 lookup <table of the network in use>`, `to 10.77.0.0/24 lookup main`). It picks wlan0 first, then v4-wwan1-3, then wwan1-3 (any IPv4 default). iOS needs configd, mDNSResponder(+Helper), trustd in the job list plus a DHCP request (`net_test dhcp en0`, in the default JOBS).
* Camera: an Android app `com.cubs.cam` (`pcwork/camapp`) opens the Android camera (id 0 rear / 1 front) as a **foreground service** and streams I420 frames to `camsrv` (127.0.0.1:7777); camsrv converts to RAW10 in the size/Bayer order iOS asked for and writes it to the camera ring; the patched fake sensor in `bsd/dev/redwood_camera.c` (`cam=5 cam_fake=1 cam_fake_fps=15 cam_bridge=1`, synthetic 1280x960 mode `bridge_tab`) copies it into the capture ring. A root shell cannot use the camera itself (its SELinux domain `u:r:ksu:s0`: the HAL cannot get buffers; `runcon` is refused), hence the app (built on the Mac with a downloaded JDK 21 + r8/d8 + aapt2 + the phone's framework-res.apk, `~/buildapk.sh`; v1-signed, targetSdk 29, `directBootAware` so it starts before the first unlock; started with `am start-foreground-service ... CamService` BEFORE `stop surfaceflinger`).
* Dual boot: Android default. KernelSU module `ios_boot` (`/data/adb/modules/ios_boot`, source `pcwork/ios_boot_module`) starts `ios_start.sh` when the flag file `/data/local/ios/boot_ios` exists (the module consumes it: one-shot) or after 3 volume-down presses within 60 s of boot. `sh /data/local/ios/ios_next.sh` touches the flag and reboots. Return to Android: hold power + volume down for 3 s on iOS (XNU writes BYE1, netsrv/shell watcher does `sync; reboot`), or hardware long press (~8 s, not clean), thermal guard (battery >43 C or BIG >80 C), or test boot-arg `cubs_bye_after=S`.
* Buttons: aoss pinctrl PA 0xE500000 (4 KiB per pin): power 114, volume down 117, volume up 118, active low, level at +0x1c bit 0. `cubs_touch.c.inc` polls them (and the touch controller) and posts REDWOOD_BUTTON_DOWN/UP; the injected backboardd library turns them into HID consumer-page events (`userland/src/inject.c`, `send_button`). The power key is posted by default now (`cubs_power_post=0` turns it off).

---------------------------------------------------------------------------------------------------

## 2. Access and tools (set these up first)

**Mac** (the phone is plugged into it): `<mac-host>`, user `<user>`, direct SSH (earlier it was a Tailscale address behind a proxy). Key: the PC's `claude-windows` ed25519 key is in the Mac's `~/.ssh/authorized_keys`. adb/fastboot live in `/opt/homebrew/bin` on the Mac (not on PATH in ssh sessions: `export PATH=$PATH:/opt/homebrew/bin`). Mac shell is zsh; macOS has **no `timeout`** (use `perl -e 'alarm N; exec @ARGV' cmd`) and **BSD sed/awk** (no `sed -i` without a suffix, no gawk functions).

PC wrappers (recreate if `/tmp` was wiped; the PC is Windows with Git Bash):
```bash
printf '#!/bin/bash\nexec ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no <user>@<mac-host> "$@"\n' > /tmp/m.sh
printf '#!/bin/bash\nexec scp -q -o StrictHostKeyChecking=no "$1" <user>@<mac-host>:"$2"\n' > /tmp/s.sh
# use:  bash /tmp/m.sh 'command on the Mac'     bash /tmp/s.sh localfile remote_name_in_Mac_home
```
**Always convert files to LF before copying them to the Mac or phone** (`sed -i 's/\r$//' file`); CRLF made `ios_start.sh` a syntax error once and iOS silently did not start.

**Root on the phone** (adb shell is uid 0 but SELinux context `ksu`; use the KernelSU wrapper for everything that touches `/dev/cubs_*`):
```bash
adb shell "echo '<commands>' | /data/adb/ksu/bin/ksud debug su"
# multi-line/quoted commands: write a script file, adb push it to /data/local/tmp, then:  ... 'sh /data/local/tmp/x.sh'
```
Quoting nested ssh -> adb -> ksud is fragile: write a small script, push it, run it.

**Repo (PC)**: `<workdir>` (not a git repository at the moment). Important parts:
* `IOS_BOOT_CHECKLIST.md` - the log. `HANDOVER.md` - this file.
* `pcwork/ios_start.sh` - the production iOS launcher (deployed to `/data/local/ios/`). `pcwork/ios_boot_module/` - the KernelSU module.
* `pcwork/xnu/*.c.inc` - kernel pieces appended to `osfmk/arm64/loader_return.c` by `~/mac_build.sh`: `cubs_blit.c.inc` (display blit, kernel screenshots, `cubs_shot`), `cubs_touch.c.inc` (touch, buttons, return-to-Android, wall clock, thread/stack dumps, selfpress/bye test aids), plus `cubs_gpu*` and the Metal shim sources/patch scripts.
* `pcwork/net/` - `netsrv.c`, `netsrv.sh`, `redwood_cubs_net.c`, `redwood_cubs_sound.c` (NEW), `camtest.c`.
* `pcwork/camapp/` - Android app (`src/com/cubs/cam/{CamActivity,CamService,SndService}.java`, `AndroidManifest.xml`), `camsrv.c`, `sndsrv.c` (NEW), `apkbuild` helpers.
* `pcwork/glfwd/` - GL forwarding (`gl_fwd.c/.h`, `glsrv.c`, `build_gl.sh`).
* `pcwork/mac_scripts/` - **copies of the Mac-only scripts** made today for durability: `cycle.sh` (the experiment runner), `run_ios.sh`, `build_and_run.sh`, `mac_build.sh`, `buildapk.sh`, `mkadt_smp.py`, `symb2.py` (symbolication), `ringrd.c`, `rmicons.c`, `rmls.c`, `mgcam.c`, `mgfast.c`, `mgpatch.c`, `mghelper.m`, `patchcam.py`, `fbgrab.sh`, `jobs_perf3.txt`. NOTE: the copied `cycle.sh` still contains dead blocks (`PICGRAB`, `FBGRAB`: they do not work, ignore them). The live versions are on the Mac in `~`.

**Mac layout** (`$HOME`):
* `~/unixnu-pixel11/hackios-upstream` - the HackiOS tree: `xnu-src/xnu-8796.121.2` (kernel, modified), `userland/` (build.sh, mkjobs.py, rc.jobs.*, src/*.c|.m), `ios165/` (unpacked IPSW root file system incl. `rootfs/System/Library/LaunchDaemons`, dyld shared cache), `docs/`.
* `~/run_ios.sh NAME [WAIT] ["extra job lines"]` -> builds the userland root image + XNU payload through `~/build_and_run.sh` and `~/mac_build.sh`; with `NOLAUNCH=1` it only builds and prints `built: ~/pcwork/hopay2/NAMEr.payload`. Check `grep -c error ~/xnu_build_blit.log` after a build (compile errors are otherwise silent and the OLD kernel gets deployed).
  * Env knobs: `IOS_EXTRA` (labels appended to the launchd job list; default now = configd, mDNSResponder(+Helper), trustd, mediaserverd, nanoregistryd, nanoregistrylaunchd), `OSLOG` (labels whose os_log goes to the console), `JOB_PROGRAM` (label=path program override), `EXTRA_JP`/`EXTRA_FILES2`, `ALLOW=audio` (let DENY'd label words through in mkjobs), `NOAUDIO=1` (leave the RedwoodAudio HAL out), `CAM=1` (adds the camera boot-args), `CPUS=2` (second XNU core), `ADT=` (device tree file).
  * Boot-args are assembled in `build_and_run.sh`: `debug=0x8 keepsyms=1 cpus=${CPUS:-1} rd=md0 loader_return_after=100000 cubs_blit=3 cubs_touch=1 cubs_touch_div=16 <CMDEXTRA>`; `run_ios.sh` sets `CMDEXTRA="gl=1 cubs_net=1"`. Important: the **first** occurrence of a boot-arg wins, so an extra `cpus=2` after `cpus=1` does nothing (that cost three runs).
* `~/cycle.sh NAME "JOBS" "BOOTARGS" WAIT_SECONDS "GREP_EXTENDED_PATTERN"` - **the experiment runner**: builds (via a sed'ed copy of run_ios.sh that appends `cubs_bye_after=WAIT+150 BOOTARGS`), checks for build errors, pushes the payload to `/data/local/ios/ho.payload`, `ios_next.sh` (reboot into iOS), sleeps WAIT, dumps the XNU log (48 MB of the XNU RAM span `E922000000:30000000`), **re-attaches the ring**, prints matching log lines, runs optional extras, and finally restores `ho.payload.prod` and reboots into Android. Env knobs: `TAILN`, `POST` (commands run as root on the phone after the dump, via a pushed script), `SMP=1`, `CPUS`, `ADT`, `DUMPMB`, `SHOTGRAB=1` (pull the kernel screenshot to `/tmp/shot.bin` on the Mac). The log is then in `/tmp/live.bin` on the Mac: `strings -n 5 /tmp/live.bin | grep -a ...`.
  * Timing: WAIT counts from the reboot command. The kernel log time at the dump is roughly WAIT minus 70 s (`WAIT 200` ~ kernel t 105-130 s; SpringBoard is up at ~90 s; the touch/buttons thread starts at ~56 s kernel time). The log dump happens BEFORE the screenshot grab (a few seconds apart).
  * Long waits: run the cycle in the background and sleep in a separate background command (`run_in_background`), e.g. `(timeout 640 bash /tmp/m.sh "export ...; bash ~/cycle.sh ..." > /tmp/x.out 2>&1 &); sleep 450; tail /tmp/x.out`. A foreground `sleep` > a few seconds is blocked by the harness; `sleep N` inside `run_in_background` is fine. Do NOT `pkill -f cycle.sh` a cycle you still want (that left a test payload staged once).
* Other Mac files: `~/pcwork/hopay2/*.payload` (builds), `~/hopay/ho.adt` (device tree; `ho_smp.adt` = two-core tree), `~/apkbuild` (Android app build tree: `r8.jar`, `aapt2`, `android-all.jar`, `framework-res.apk`, `debug.keystore`; JDK at `/opt/homebrew/opt/openjdk@21`), `~/mkadt_smp.py`, `~/symb2.py`, `~/ringrd`, `~/camsrv`, `~/sndsrv`, `~/netsrv`, `~/libmgcam.dylib`, `~/rmicons`, `~/rmls`, `~/andboot/` (boot images; **boot_a.ORIG.img = stock backup**), `~/factory/` (factory OTA modem image etc.).
* Android NDK: `/opt/homebrew/share/android-ndk` (`$T/bin/aarch64-linux-android31-clang -O2 -o out src.c`). iOS binaries: `source ~/unixnu-pixel11/hackios-upstream/xnu-env.sh; export THEOS=$HOME/unixnu-pixel11/theos; xnu-clang -arch arm64 -isysroot $THEOS/sdks/iPhoneOS16.5.sdk -O1 ...` (add `-undefined dynamic_lookup` for dylibs referencing Apple private symbols).

**Phone files** `/data/local/ios/`: `ho.payload` (what runs), `ho.payload.prod` (the production build; every cycle restores it), `cubs_stage.ko`, `drmfb2`, `mtlsrv`, `glsrv`, `netsrv`/`netsrv.sh`, `camsrv`, `system.img`, `ios_start.sh`, `ios_next.sh`, `env.sh` (RAMOFF=28b4000, LISTOFF=17fe00000), `fblist.bin`, logs (`ios_start.log`, `netsrv.log`, `camsrv.log`, `temps.log`, `boot_hook.log`, `glsrv.log`). **Flag files** (presence = feature on; remove when done): `boot_ios` (one-shot, start iOS at next boot), `cam` (start the Android camera service + camsrv), `camid` (content `0` rear / `1` front), `camdelay` (seconds before the app opens the camera), `noring` (camsrv does not open the ring), `smp` (offline CPU5 + pin its cluster for the two-core test), `snd` (start SndService + sndsrv; NEW). `cpu6_khz` (content = kHz for CPU6; 4.1 GHz overheats: BIG hits 80 C).

Current phone state when this was written (2026-11-04 22:05): **in Android**, no flag files, `ho.payload` == `ho.payload.prod` (default build with mediaserverd + nanoregistryd + libmgcam), app `com.cubs.cam` installed (probably the camera-only version: the last install command that carried the new sound pieces failed with exit 255 after the adb pushes; `sndsrv` is NOT in `/data/local/ios/`, `snd` flag not set). Verify with:
```bash
bash /tmp/m.sh 'export PATH=$PATH:/opt/homebrew/bin; adb devices; adb shell "uptime; ls /data/local/ios; pm path com.cubs.cam; cmp /data/local/ios/ho.payload /data/local/ios/ho.payload.prod && echo prod"'
```

---------------------------------------------------------------------------------------------------

## 3. Status of every feature (evidence in the checklist)

| feature | status |
|---|---|
| Dual boot (Android default, iOS on request, clean return by 3 s power+vol-down) | **works** (software return tested via `cubs_bye_after`; real hold gesture not tested by a person) |
| Display, touch, home screen, lock screen | works; frame rate 10 fps idle / **14-15 fps swiping** (not CPU-bound) |
| Wi-Fi internet for iOS | **works** (DHCP, DNS, HTTP, HTTPS). iOS shows it as Ethernet (no Wi-Fi network list) |
| Mobile data for iOS | **works** (tested with Wi-Fi not connected: netsrv picked `v4-wwan2`) |
| Wall clock | works (from Android through the ring); home screen shows correct time/date |
| Buttons | all three keys are read and reach backboardd; **volume overlay/volume change do not happen** (see 4.1); power key sleep/wake worked with a *simulated* press (after the clock fix), **never tested with a real finger** |
| GPU acceleration | works (GL forwarded to the PowerVR, Metal shim) |
| Audio server (mediaserverd) | **works now** (needed `com.apple.nanoregistryd`); `sound_test` plays a 3 s tone into `/dev/redwood-audio` (kernel logs "playing ... stopped after 5.14 s"), but **nothing plays on the phone yet** (sink missing: in-flight work, section 5) |
| Cameras | Android cameras -> iOS camera device **works** (iOS `camera_test` read real frames; AVFoundation lists Back and Front cameras with all formats). **Camera.app opens** (real viewfinder in a screenshot) via `battery_test open camera://` after the unlock swipe, its icon is hidden by SpringBoard. **Live Android picture in Camera.app's preview: never seen** (see 4.2) |
| Second XNU core | starts (needed an EL2->EL1 drop in `osfmk/arm64/start.s`) and is stable with CPU5's cluster clock pinned, but gives only ~16 fps; opt-in |
| Calls / SMS | **not attempted** (the modem in dmesg is MediaTek PCIe (`mtk_pci_drv`); needs a Telephony bridge through Android; deprioritize) |

---------------------------------------------------------------------------------------------------

## 4. Open problems and what is known

### 4.1 Volume keys / HUD
* backboardd logs every press: `[Button] VolumeIncrement page:0xC usage:0xE9 downEvent:1 down` / `VolumeDecrement ... 0xEA`, earlier with `destinations:<none>`. No `redwood: audio: the volume is ...` line ever appears (the audio plug-in `userland/src/audio_plugin.c` logs every volume setting), so SpringBoard never changes the volume; the HUD never shows.
* Power key (Lock page 0xC usage 0x30) also had `destinations:<none>` but SpringBoard did react (display sleep: IOMFB selector 12 with 0).
* SpringBoard thread stacks at ~100 s (symbolicated, see tools below): ~20 threads, about half in synchronous XPC waits (TCC, CoreTelephony, MediaRemote/MediaServices, CallKit, Focus/AppPrediction), the rest idle. Daemons added without effect: tccd, mediaremoted, mediasetupd, coreduetd, accountsd, biomed, callservicesd (the last tests were inconclusive for timing reasons: the volume run must be dumped AFTER the presses, e.g. WAIT 280).
* The iOS HUD for media volume needs an active audio output; the earlier test that tried tone + presses at the same time had a non-running `sound_test` (the `&` job syntax ended immediately). **Do this after the sound sink works**: play a long tone (`sound_test springboard route wait 2 tone 60`) in one job and press volume (`rwtouch button volup ...`) in another, screenshot with `SHOTGRAB=1`.
* Ideas: log backboardd at debug level; find what registers hardware-button handlers (BKSHIDEventDeliveryManager / SBHardwareButtonService); check that the injected event is complete (`inject.c` `send_button`: keyboard event with FIELD_IS_BUILT_IN; maybe missing sender/display attributes); compare with upstream's `rc.jobs.volume` (which expects `sound=4 adsp=1` on the real phone).

### 4.2 Android live camera preview in Camera.app
* With the Android camera service started before iOS (`/data/local/ios/cam`), the iOS kernel log often **stops at ~58-60 s** (last lines `CUBS blit: frame 1`/`holds`, or `camera: bridge step header read`), BIG temperature not idle. Observed with: camsrv ring writes on or off (`noring`), camera opened late (`camdelay`), surfaceflinger/hwcomposer stopped, display DPMS On, no display/bus errors in Android dmesg. One earlier run with the service worked and produced real frames (cam5, pic2), so it is intermittent/unexplained. An `io_map` of the 15 MB camera ring inside the frame thread caused another hang; it is now mapped early (`bridge_map_early`).
* Runs WITHOUT the Android camera service (chart frames) never stopped.
* Ideas: (a) check whether the hang is a DPU fabric timeout (memory note: "DPU fabric-timeout trap") caused by Android power/clock votes when the camera HAL starts (look at `dmesg` clock/regulator lines at that time, try pinning CPU/GPU/DDR governors, or start the Android camera service only after the first iOS blit is done: needs a way to start a foreground service without the display, e.g. keep SurfaceFlinger running until the service is up and stop it later, which conflicts with DRM); (b) start the camera service long BEFORE starting XNU and wait until Lyric/camera HAL settles (add `sleep 20`); (c) bisect `cubs_shot`, `cubs_bye_after`, mediaserverd, etc.; (d) look at `/data/local/ios/temps.log` and `dmesg` timestamps around the stop.
* To test the picture without the service-start problem: use the kernel screenshot with the front camera (`camid` 1, front sees a pale wall/ceiling).
* Camera.app has no icon on the home screen (SpringBoard drops apps whose UIRequiredDeviceCapabilities fail; `libmgcam.dylib` answers true for the camera keys in lsd/SpringBoard/Camera, and `rmicons`/`rmls` (delete IconState / LaunchServices caches at boot) did not bring it back). Open it with `battery_test open camera://`.

### 4.3 Smooth swipes
* Idle 10 fps, swiping 14-15 fps (62 ms per frame; 120 Hz panel). Not the CPU clock (4.1 GHz same rate, overheated), not the GL server (busy ~25%), not `cubs_blit_ms`, not `fb_hz=120`. Second XNU core: 15-16 fps. Server side: `READ_PIXELS_DELTA` ~22 ms per frame. Client side: ~7 batches/frame, many synchronous round trips; ring polls (client `usleep(100)`, server `usleep(300)`).
* Ideas: asynchronous readback (PBO / one-frame pipeline) in `pcwork/glfwd/glsrv.c` + `gl_fwd.c`; remove synchronous `glGen*` round trips (client-side name pools: careful, the shadow keys rely on server-returned names); let the server write straight into the IOSurface pages through the ring; measure with the IOMFB "N frames in 5000 ms" lines and glsrv batch rates (`cycle.sh jobs_perf3.txt`: scripted swipes via `rwtouch`).

### 4.4 Power-key wake with a real finger
Needs the user (or run `cubs_selfpress=60` test aid). Simulated presses: sleep (selector 12 = 0) then wake (selector 12 = 1, then 79) and the lock screen came back in ~12 s once the clock was right. If the panel stays black after a real press, boot with `cubs_power_post=0` to stop posting the key to iOS.

### 4.5 Calls / SMS
Not started. MediaTek modem via Android; realistic route would be an Android-side bridge (SmsManager/TelecomManager) exposed to iOS through a fake CommCenter. Lowest priority.

---------------------------------------------------------------------------------------------------

## 5. IN-FLIGHT WORK: sound out of iOS (finish this first)

Proven: iOS's audio stack works up to the kernel (`sound_test: route: "Speaker"`, `AudioQueueStart: 0`, `144000 of 144000 frames handed over`, kernel `redwood: audio: playing` ... `stopped after 5.14 s (0 frames not taken by /dev/redwood-audio)`). The kernel driver `bsd/dev/redwood_audio.c` hands PCM (48 kHz, 16-bit stereo, 4 bytes/frame) to a *sink* registered with `redwood_audio_set_sink(name, uint32_t (*sink)(const int16_t *frames, uint32_t count))` (returns how many frames it took; the rest is dropped). Volume: the plug-in sends `REDWOOD_AUDIO_SET_VOLUME` (attenuation in 1/8 dB + muted flag); the sink API does not see it (apply it on the Android side if you want).

Written today but **NOT built, deployed or tested**:
1. `pcwork/net/redwood_cubs_sound.c` -> already copied to the Mac xnu tree as `bsd/dev/redwood_cubs_sound.c`, added to `bsd/conf/files`, and `redwood_cubs_sound_init()` is called from `redwood_net_init()` in `bsd/dev/redwood_net.c`. Boot-arg `cubs_sound=1`. It maps the audio ring (PA 0xab2000000+0x1A00000) 2 s after init and registers the sink; it only accepts frames when `sndsrv` has written the magic `AUD1`.
2. `pcwork/camapp/sndsrv.c` (Android root daemon): waits on `127.0.0.1:7778` for the player, writes `AUD1`, drains the ring and sends the PCM to the player (empties the ring while nobody listens).
3. `pcwork/camapp/src/com/cubs/cam/SndService.java` (+ manifest entry): foreground service, connects to sndsrv, plays through `AudioTrack` (48 kHz stereo PCM16), logs `played N frames, last peak P` to logcat tag `CubsSnd`. (A root process cannot use AudioTrack for the same SELinux reason as the camera; the app can.)
4. `pcwork/ios_start.sh`: with flag `/data/local/ios/snd` it starts `SndService` before `stop surfaceflinger` and `sndsrv` after `netsrv`.

Steps to finish:
```bash
# on the PC (repo) -> Mac
bash /tmp/s.sh pcwork/camapp/sndsrv.c sndsrv.c ; bash /tmp/s.sh pcwork/camapp/ios_start.sh ... (use pcwork/ios_start.sh) ; bash /tmp/s.sh pcwork/camapp/src/com/cubs/cam/SndService.java apkbuild/SndService.java
bash /tmp/s.sh pcwork/camapp/AndroidManifest.xml apkbuild/AndroidManifest.xml ; bash /tmp/s.sh pcwork/net/redwood_cubs_sound.c redwood_cubs_sound.c
# on the Mac: ~/buildapk.sh must list SndService.java in its javac line (it does: "CamActivity.java CamService.java SndService.java")
bash ~/buildapk.sh ; $T/bin/aarch64-linux-android31-clang -O2 -Wall -o ~/sndsrv ~/sndsrv.c
adb push ~/apkbuild/app.apk ~/sndsrv ~/ios_start.sh /data/local/tmp/      # then as root: pm install -r -g app.apk; cp sndsrv ios_start.sh to /data/local/ios; chmod 755; touch /data/local/ios/snd
```
Then a cycle with the audio test, kernel built with `cubs_sound=1`:
```bash
bash ~/cycle.sh snd2 '/redwood/bin/sound_test springboard route wait 2 tone 5' 'cubs_sound=1' 220 'sound:|sound_test:|redwood: audio'
# on Android afterwards: cat /data/local/ios/sndsrv.log ; logcat -d | grep CubsSnd      (expect "played 48000 frames, last peak ~16000")
```
Things to watch: the `cs_sink` `io_map` happens in a thread_call 2 s after init (if it hangs like the camera ring, map it at init time like `bridge_map_early`); `RING_FRAMES*4` = 64 KiB ring; the kernel prints `sound: ring to Android: ...` roughly every 131072 frames; if `AUD1` is not seen XNU drops everything silently.

---------------------------------------------------------------------------------------------------

## 6. Debug methods that worked (reuse them)

* **Kernel screenshot** (`cubs_shot=1`): quarter-size copy of the iOS framebuffer in the ring at +0x1C00000; `cycle.sh` with `SHOTGRAB=1` leaves `/tmp/shot.bin` on the Mac (it uses `~/ringrd 0x1C00000 0x400000 file`, a `pread` helper; `dd skip/seek` on `/dev/cubs_ram` is unreliable). Convert on the PC: read `/tmp/shot.bin` (`bash /tmp/m.sh 'cat /tmp/shot.bin' > shot.bin`), header `<4sIII>` magic/seq/w/h, pixels BGRA at +0x1000 (540x1212), write a PNG with `zlib` taking every 2nd pixel; the Read tool can display PNGs. Open Camera: jobs `/redwood/bin/sound_test springboard;/redwood/bin/rwtouch wait 5 swipe 0.5 0.985 0.5 0.3 200 wait 8;/redwood/bin/battery_test open camera://;/redwood/bin/rwtouch wait 60`.
* **Scripted touches**: `/redwood/bin/rwtouch wait N swipe x0 y0 x1 y1 ms tap x y button volup|voldown|power ...`; arguments longer than ~250 characters are cut: chain several `rwtouch` jobs with `;`.
* **Kernel thread / user-stack dump**: boot-arg `cubs_threads_after=S` prints, for mediaserverd/SpringBoard/backboardd/launchd/runningboardd/lsd, every thread's wait state (`CUBS threads: ... cont ... hint N`, hints in `osfmk/kern/block_hint.h`) and `CUBS stack: ... pc lr frames` (user registers + frame-pointer chain via `pmap_find_phys`). Symbolicate with `~/symb2.py` (reads `/tmp/stk_lines.txt` on the Mac; parses the dyld shared cache image table in `ios165/20F66__iPhone10,3_6/dyld_shared_cache_arm64` and finds the slide by requiring the trap-stub PCs to land in libsystem_kernel; slide differs per boot). This found the mediaserverd deadlock (NanoRegistry waiting for `nanoregistryd`).
* **Console logging of iOS processes**: env `OSLOG='com.apple.backboardd com.apple.SpringBoard com.apple.mediaserverd'` while building (their os_log lines then appear in the XNU log; compare healthy vs failing runs by unique message sets).
* **Picture kept by `camera_test`**: the kernel prints its physical address (`camera: a picture from iOS for the host: ... at 0x9bb044000`); while iOS is still running read it with `printf E<pa>:200000 > /dev/cubs_go; printf O0 > /dev/cubs_go; dd if=/dev/cubs_ram of=pic.bin bs=1M count=2` then re-attach the ring; header "RWCAM001", NV12 data at +4096.
* **Android-side camera test without iOS**: `camtest.c` (NDK) fails as root (no frames); use the app: `am start-foreground-service --user 0 -n com.cubs.cam/com.cubs.cam.CamService --es id 1 --ei w 640 --ei h 480` (display must be up), `CAMSRV_SAVE=30 /data/local/ios/camsrv` writes `/data/local/tmp/cam_last.i420`.
* **Network checks**: `net_test` job lines (`/redwood/bin/net_test wait 100 show dhcp en0 waitaddr en0 60 resolve example.com fetch https://example.com/`), Android side `/data/local/ios/netsrv.log`, `iptables -L FORWARD -n -v`, `ip rule | grep 9000`.

---------------------------------------------------------------------------------------------------

## 7. Traps (each one cost the previous assistant at least one cycle)

* After dumping the XNU log you MUST re-attach the ring (`printf Eab2000000:10000000 > /dev/cubs_go; printf O0 > /dev/cubs_go`), otherwise the Android servers (glsrv/mtlsrv/netsrv/camsrv/sndsrv) write into iOS's own memory. `cycle.sh` does it. The `O` offset does not apply to `dd`/`printf` on `/dev/cubs_ram` in E-attached mode: use `pread`/`pwrite` with explicit offsets (small C tools).
* The framebuffer PA (0xaa1400000) is Linux RAM: `E<pa>` reads return 0 bytes. Use the SHOT ring.
* Python/bash heredocs: an unquoted heredoc delimiter expands `$(...)`/backticks (it mangled `cycle.sh` once); inside Python triple-quoted strings `\n` becomes a real newline in C `printf` format strings: build the backslash with `chr(92)`. Always `grep` the result after patching. BSD sed on the Mac: `sed -i.bak ...`, no `\n` in replacements; prefer small Python patch scripts (`python3 patch.py` on the Mac).
* `cycle.sh`'s reboot step can hang `adb shell` (device vanishes mid-command); the Mac copy now wraps it in `perl -e "alarm 25; exec @ARGV"`. `adb: no devices` for a few minutes after a reboot is normal.
* Never add `com.apple.mediaserverd` without `com.apple.nanoregistryd` (SpringBoard and the audio server then wait forever; panel stays black).
* Adding a boot-arg after an existing one of the same name does nothing (first wins).
* The `cubs_threads_after` counter starts when the touch thread starts (~56 s kernel time) and counts 2 ms ticks (500/s).
* Pixel has 7 cores (0-6); XNU boot core = CPU6; CPU5 is in cluster `policy2` (cpus 2-5) which Android governs: pin it (`echo 2500000 > .../policy2/scaling_{max,min}_freq`) for two-core tests. CPU6 default clock 3.033 GHz; 4.1 GHz overheats (BIG 80 C thermal stop reboot).
* `settings`: Android must stay awake and unlocked-ish: `ios_start.sh` does `input keyevent KEYCODE_WAKEUP; svc power stayon true`, stops surfaceflinger + vendor.hwcomposer-3 and runs `drmfb2 ... hold`.
* The Android camera service must be started while the display is still up (before `stop surfaceflinger`); an Activity start fails with error -96 once the display is stopped.
* `adb shell getprop gsm.sim.state` shows `NOT_READY,LOADED`; mobile data still works (`v4-wwan*`/`wwan*` default route). Saved Wi-Fi is not joined after an Android reboot until the phone is unlocked once.
* Files edited on the PC: LF endings. The Mac xnu tree has stale `.pre-*` copies of `loader_return.c`; `mac_build.sh` always starts from `~/loader_return.c.bak-blit` and appends the `.c.inc` files, so edit `cubs_*.c.inc`, not `loader_return.c`.
* Don't leave `cubs_bye_after`, `cubs_shot` or the camera flags in the production payload/phone. `ho.payload.prod` = clean default (`run_ios.sh prod 0`, then copy to `/data/local/ios/ho.payload.prod`). Rebuild it after kernel changes you want to keep: `NOLAUNCH=1 bash ~/run_ios.sh prod 0` then `adb push ~/pcwork/hopay2/prodr.payload /data/local/tmp/prod.payload` and `cp` it to both `ho.payload` and `ho.payload.prod` as root.

---------------------------------------------------------------------------------------------------

## 8. Suggested plan until Saturday (priority order, token-frugal)

1. **Finish the sound path** (section 5): deploy, one cycle, verify `CubsSnd played ... peak` on Android. Success criterion: the Android log shows non-zero audio frames with a sensible peak when iOS plays the tone; ask the user to listen once.
2. **Volume HUD**: with real audio playing and the keys pressed, check `redwood: audio: the volume is ...` and take a screenshot during the presses. If still nothing, dig into how SpringBoard registers for hardware buttons (section 4.1).
3. **Camera preview stability** (4.2): bisect the early kernel stop; try starting the camera service well before XNU; compare `dmesg` around ~58 s; if solved, take a Camera.app screenshot with `cam_bridge=1` and `camid 1` showing the live picture.
4. **Swipe speed** (4.3): async GL readback; measure with `jobs_perf3.txt`.
5. Ask the user for real-finger checks: power-key wake, volume keys, the 3 s return gesture, Camera via the link.
6. Keep `IOS_BOOT_CHECKLIST.md` current (append a dated section per result) and tell the user, in two or three sentences, what changed and what is unverified. When the user says the project is finished, do the cleanup in section 0.7.

What NOT to waste time on: more CPU frequency tests, `fb_hz`/`cubs_blit_ms` tuning, mediaserverd plug-in/timeout theories (solved), the CPU7/"cpu7" idea, trying to run the camera or audio from the root shell (SELinux), capturing the screen with `drmfb2` SIGUSR1 (it only dumps its own test pattern).

---------------------------------------------------------------------------------------------------

## 9. Quick reference: commands

```bash
# reboot into iOS (production build) and let it run; return by holding power+volume-down 3 s or:  adb shell reboot
bash /tmp/m.sh 'export PATH=$PATH:/opt/homebrew/bin; adb shell "echo \"sh /data/local/ios/ios_next.sh\" | /data/adb/ksu/bin/ksud debug su"'

# one experiment (example: Camera.app screenshot with the Android camera bridge, front camera)
bash /tmp/m.sh 'export PATH=$PATH:/opt/homebrew/bin; adb shell "echo \"echo 1 > /data/local/ios/camid; touch /data/local/ios/cam\" | /data/adb/ksu/bin/ksud debug su"'
(timeout 640 bash /tmp/m.sh "export SHOTGRAB=1 TAILN=6; bash ~/cycle.sh try1 '/redwood/bin/sound_test springboard;/redwood/bin/rwtouch wait 5 swipe 0.5 0.985 0.5 0.3 200 wait 8;/redwood/bin/battery_test open camera://;/redwood/bin/rwtouch wait 60' 'cam=5 cam_fake=1 cam_fake_fps=15 cam_bridge=1 cubs_shot=1' 215 'camera: bridge|CUBS shot: [0-9]'" > /tmp/try1.out 2>&1 &)
# ... wait ~8 min in a separate background sleep, then fetch /tmp/shot.bin from the Mac and convert it (section 6)
# afterwards: rm the flag files on the phone (cam camid camdelay noring smp snd) and confirm "payload-is-prod"
```
Per-session safety check before finishing: phone in Android, `ls /data/local/ios` shows no flag files, `cmp ho.payload ho.payload.prod` equal.
