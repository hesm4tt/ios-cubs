# Notice

This repository is a derivative work and a set of additions. It does not contain Apple's or Google's proprietary software.

## Upstream

* **HackiOS** — `oosexgang/hackios-xnu-kernel` and `oosexgang/hackios-xnu-userland`, by OOSEX GANG. The files in `overlay/` are modified or new versions of files from that project (and of Apple's XNU through its patch set) and keep the license that applies to the original files. This repository (a GitHub fork of the kernel project) is intended to be used together with a checkout of those projects.
* **Apple XNU** (`xnu-8796.121.2`) — Apple Public Source License 2.0, text in `LICENSE.APSL`. `overlay/xnu/redwood.patch` is a patch against that source.

## Not included

No iOS system image or IPSW, no Apple frameworks or binaries, no Android or Pixel firmware, device trees, kernel or boot images, no captured traces from a device, and no device identifiers. Build outputs (`*.payload`, `*.img`, `*.apfs`, `*.ko`) are ignored by `.gitignore`.

## Trademarks

iOS, iPhone and Apple are trademarks of Apple Inc. Pixel and Android are trademarks of Google LLC. This project is not affiliated with or endorsed by either company.

## Other third-party code

Individual files may carry their own notices; keep them when copying. Components under `pixel/gpusrv` use Rust crates listed in its `Cargo.toml`, each under its own license.
