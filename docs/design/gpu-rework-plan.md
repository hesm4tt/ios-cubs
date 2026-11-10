# Plan: make iOS rendering fast and consistent (GL path first, then Metal)

## Context
iOS 16.5 (XNU on CPU6 beside Android) feels sluggish: swipes 13-15 fps, idle a constant 10 fps. Measured per frame (checklist "GPU rework analysis", agent map of the code): ~62-75 ms = ~50 ms CoreAnimation/UIKit CPU on ONE XNU core + ~26 ms in our GL library, of which ~15-22 ms is the **READ_PIXELS_DELTA readback** (GPU -> CPU -> shared ring -> iOS IOSurface -> XNU blit into the Linux scanout pages -> XNU replays the DPU commit, ~5 ms) and ~8 ms is refilling a 10.8 MB IOSurface texture every frame. Everything is serial: client batch -> server draw -> readback -> client copy -> blit. Already tried and not helpful: more XNU cores (15-16 fps), clock/DSU pinning, no-flush, PBO full-frame readback (worse), dirty-rect readback (every draw has a full-screen scissor), lower fbscale (erratic). So the readback and the serial pipeline are the structural cost; the CPU cost of CoreAnimation is the next ceiling.

## What similar public projects do (research, 2026-11-09)
- **gfxstream / Cuttlefish / virtio-gpu (Google, QEMU, crosvm)**: exactly our model (guest GLES/Vulkan calls streamed to the host GPU, host executes). Their display path never reads pixels back to the guest: the host presents the rendered buffer itself. ([Cuttlefish GPU doc](https://source.android.com/docs/devices/cuttlefish/gpu), [QEMU virtio-gpu](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html))
- **Zero-copy scanout** (KVM Forum 2021 "Passthrough Headless GPU Gets Ahead"): the guest framebuffer is a dma-buf/blob resource shown directly on a hardware plane, removing the CPU and GPU copies. ([slides](https://kvm-forum.qemu.org/2021/Passthrough_Headless_GPU_Gets_Ahead.pdf))
- **Android's own DRM display path**: buffers from gbm/minigbm (`gbm_bo_create`), exported as dma-buf fds, put on screen with `drmModeAtomicCommit`; Vulkan can import/export such buffers (`VK_EXT_external_memory_dma_buf`). ([AOSP doc](https://source.android.com/docs/automotive/sdv/workstreams/media/managing-displays), [Vulkan ext](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_external_memory_dma_buf.html))
- **Corellium** (iOS virtualization) advertises hardware GPU through OpenGL ES pass-through, i.e. the same GL-forwarding approach we use (no public Metal implementation).
- **Metal on Vulkan**: Darling's [Indium](https://github.com/darlinghq/indium) (+ Iridium AIR->SPIR-V, 0BSD, Vulkan 1.3 + timeline semaphores, no releases, internal-library style) and our own `metal2vulkan`/`mtlsrv` (Rust; verified compute/render/depth/MSAA; MetalDemo ran 20 min at steady 66 ms). MoltenVK is the opposite direction. Conclusion: keep our metal2vulkan (it already runs on the PowerVR and covers what iOS apps used so far); borrow ideas from Indium (timeline semaphores, dynamic state) only where a feature is missing; the Metal problem is not translation but **presentation** (below).
- No public project runs real iOS on a phone SoC GPU with PowerVR; nobody has solved scanout for this exact case, so we use the generic pattern above.

## Recommended solution
**Stop reading pixels back. Let the host GPU present the final frame itself, pipelined one frame ahead.** Three layers of work, in order of payoff/risk:

### Phase 0 - measure and cheap wins (hours, low risk; use `run_guarded.sh`)
1. **Profile the ~50 ms CPU on backboardd** to know the real ceiling: a kernel sampler (boot arg) that records the user PC of CPU6 each ms, symbolicated with the shared-cache tooling already used for hangs (`cubs_threads_after`, `symb2.py`). Split: CoreAnimation vs our `gl_fwd` recording/shadow/IOSurface diff vs IOMFB.
2. **Cut CoreAnimation's workload by settings** with `rwdefaults`: Reduce Transparency (removes backdrop blurs and their per-frame 10.8 MB IOSurface refills), Reduce Motion, widgets/idle timers; find what redraws every 100 ms at idle (the constant 10 fps). Measure fps/frame lines before and after.
3. **Stop re-uploading unchanged IOSurfaces** (compare the IOSurface seed in `gl_fwd.c` before the refill).

### Phase 1 - spikes to choose the presentation path (1-2 guarded boots each, Android-side tools only)
- **Spike A (preferred)**: direct scanout with zero copy while SurfaceFlinger stays stopped: from `drmfb`, allocate two gralloc/AHardwareBuffer (or GBM) scanout buffers, export the dma-buf, `drmModeAddFB2` + `drmModeAtomicCommit` page flips, and render into them with GLES/Vulkan (EGLImage / `VK_EXT_external_memory_dma_buf`). Questions it answers: does the PowerVR driver import/export these buffers with scanout-capable format/modifier, and does a plain Linux atomic commit trigger the command-mode panel (so XNU's DPU-register replay `cubs_blit_tick` becomes unnecessary)? Also print the driver's EGL/Vulkan extension list.
- **Spike B (fallback)**: present through Android's compositor like `bootanimation`/a fullscreen app (EGL window surface -> SurfaceFlinger/HWC overlay): robust and vsync-paced, but needs SurfaceFlinger running, input grab (EVIOCGRAB) so Android does not act on swipes, and Android UI suppression.
- Also test using the vendor GLES driver directly instead of ANGLE-on-Vulkan (removes a translation layer; compare the mip/readback costs).

### Phase 2 - implement the chosen path
- Server (`pcwork/glfwd/glsrv.c`): render the iOS framebuffer surface into the scanout buffer (scaling 1125x2436 -> 1080x2424 on the GPU), replace `OP_READ_PIXELS_DELTA` by `OP_PRESENT` (no pixels returned), signal flip via a ring word; keep `OP_READ_PIXELS` on demand for the `cubs_shot` screenshots and `fbdump` (the iOS RAM framebuffer is no longer updated each frame).
- Client (`pcwork/glfwd/gl_fwd.c`, Mac-only `userland/src/eagl.c`): do not wait for pixels; the IOMFB swap completes on "queued"; **one frame in flight** (client records frame N+1 while the server draws N) with a doorbell instead of 100/300 us sleeps.
- Kernel (`pcwork/xnu/cubs_blit.c.inc`, `redwood_gpu.c`): boot arg `cubs_blit=0` (blit and DPU replay off); `MiniIOMobileFramebuffer::show()` just acknowledges. Fewer DPU hacks also removes the fabric-timeout risk.
- Keep the old path selectable by flag (`gl_present=0`) for rollback; production only after two clean boots and a soak.

### Phase 3 - use the freed budget
- Remaining ceiling is iOS CPU (~50 ms before Phase 0 wins): reduce `glGen*` round trips (client-side name pools), batch/shadow overhead found by the profile; retry 2 XNU cores only after the pipeline is asynchronous (it gave nothing while everything was serial).
- Target: swipes 25-30 fps after Phase 2, 40+ if the profile shows our own library dominates the CPU; idle: no redraw churn.

### Phase 4 - Metal presentation
- Today `mtlsrv` renders on Vulkan, then `READ_TEXTURE` over the ring and a CGImage on the main queue; one process at a time (flock); 3 MB drawables, RGBA8 only.
- Fix: allocate the drawable as an AHardwareBuffer/dma-buf shared by `mtlsrv` (Vulkan image) and `glsrv` (EGLImage texture) so the compositor draws the Metal output zero-copy (iOS keeps a placeholder IOSurface); per-process ring slots instead of one mailbox; larger drawables; timeline semaphores for GPU-GPU sync (Indium's approach).

## Critical files
`pcwork/glfwd/glsrv.c` (:340 `mip_read`, :705 `OP_READ_PIXELS_DELTA`, :866 main loop), `pcwork/glfwd/gl_fwd.c` (:109 `flush`, :887 readback/delta), `pcwork/xnu/cubs_blit.c.inc` (:139, :191, :271), `pcwork/xnu/redwood_gpu.c`, `pcwork/drmfb/drmfb.c`, `pcwork/xnu/mtlshim.m`, `pcwork/gpusrv/src/bin/mtlsrv.rs`; Mac-only: `userland/src/eagl.c`, `bsd/dev/*`, `ios_start.sh`. Reuse: `run_guarded.sh` (supervised boots, screenshots, LOOP), `shot2png.py`, the heartbeat page, `rwdefaults`, existing fps lines (IOMFB "N frames in 5000 ms", `redwood-gl: frame ...` timings), `pcwork/jb/ringbw.c`, `dltest.m`.

## Verification
- Same swipe chain (`rwtouch ... swipe`) before/after: IOMFB fps lines, `redwood-gl` per-frame timings, kernel-sampler histogram; target numbers above.
- Visual check by screenshots (`cubs_shot`, `shot2png.py`) and on the real panel by the user: no tearing, correct colours/scaling, no stale frame.
- Safety every run: supervised runner, thermal guard 43 C, phone ends in Android, rollback flag `gl_present=0` and the previous payload kept (`ho.payload.pre-*`).

## Constraints (unchanged)
Phone always ends in Android; no GitHub push; no end-of-project cleanup; never `dd` raw block devices; USB-lost protocol (Discord ping) only for real physical steps; the USB/Finder work is parked (phone currently needs a replug).
