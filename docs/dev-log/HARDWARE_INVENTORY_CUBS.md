# CUBS (Pixel 11) hardware inventory for the remaining port work

Source: the saved Android runtime device tree and `/proc/iomem` (`cubs-live-android-2026-10-22-05/live.dts`, `proc-iomem.txt`, kept on the Mac) plus the bootloader's `fastboot getvar all`. Everything here is read from captures. None of it has been tried on the hardware from XNU, and the Android values are not the Fastboot-handoff state.

## Storage: UFS host (for a read-only image reader)

| Item | Value |
|---|---|
| Compatible | `google,ufshc`, node `ufs@3c2d0000` |
| Registers | host controller `0x3c2d0000` (0x3000), plus MCQ queue registers at `0x3c2d3000..0x3c2d465f`; `ufs_top` `0x3c2e0000` (0x718); `ufs_sec` `0x3c2f0000`; PHY SRAM `0x3c340000` (0xa000); `ufs_ss` `0x3c34a000`; power status words at `0x3c00b108`, `0x3c00c210`, `0x3c00d108` |
| Interrupts | one GIC SPI for the controller plus 16 more (`0x168..0x177`) for MCQ |
| Power | three power domains (`ufs_prep_pd`, `ufs_pd`, `cpu_top_cl`), GPIOs `reset`/`power`/`lss` on one expander (`0x39f`), supplies vdd0p75, vdd1p2, vcc, vccq (regulators behind the PMIC) |
| Clocks | `gpio_ref_clk`, `mphy_ref_clk`, `cp_core_clk`, `deep_h8_clk` |
| Other | `iommus = <0x82 0x8000>` (IOMMU in the path), `gsa-device` (the GSA security processor takes part), `mboxes` (a mailbox to the power/firmware processor), PHY calibration table in the node, quirks `skip-cport-setup`, `mphy-pmc-war`, `decouple-ufs-en` |
| Implication | A read-only reader is a real driver: power domains and regulators through a firmware mailbox, M-PHY calibration, MCQ rather than the legacy doorbell, an IOMMU, and GSA. The decisive unknown is how much of this the bootloader leaves initialised after `fastboot boot`. Test first by reading the controller's status registers (HCS, link state) from the shim with a bounded, read-only access, and compare with Android. |
| Fastboot facts | Partitions with slots: boot, init_boot, vendor_boot, vendor_kernel_boot, dtbo, vbmeta*, pvmfw, modem; no `super`/`userdata` in the slot list (full `getvar all` in `out/fastboot-getvar-all.txt` on the Mac). `max-download-size` 0x20000000 (512 MiB). |

## USB: dwc3 (for staged image loading)

| Item | Value |
|---|---|
| Wrapper | `usb3@a200000` (`google,dwc3-mbu`): `usbcs_host_cfg_csr` `0xa200000`, `usbcs_usbint_csr` `0xa200020`, `usb_top_cfg_csr` `0xa200028` |
| Core | `dwc3@a210000` (`snps,dwc3`), size 0xd060; SuperSpeed; `role-switch-default-mode = "peripheral"`; DMA-coherent; `iommus = <0x82 0x8200>`; TX FIFO resize quirks |
| PHY / power | Google USB PHY nodes (`google,usb_phy-mbu`), power domains `usb_psw_pd` / `usb_top_pd`, resets and clocks listed in the node; second controller `-aux` and a USB-C controller `max77759tcpc` (PD) |
| Why it is the interesting option | The bootloader's fastboot already runs this controller as a device. If its core, PHY and event/TRB rings survive into the shim, a staged loader can reuse that setup instead of bringing up clocks, resets and the PHY from scratch. The bootloader hands over to Android/XNU through a reset path we do not control, so whether the state survives is a measurement, not an assumption: read the dwc3 `DCTL`, `DSTS`, `DEPCMD` state from the shim before touching anything. |
| Caveat | Even if it survives, the host side then needs a tool that speaks our protocol over bulk endpoints (a small libusb script on the Mac), and the controller's data must land in reserved RAM outside XNU's window, covered by the IOMMU settings. |

## Display

| Item | Value |
|---|---|
| Controller | Verisilicon `dc9x00` (`dpu`): front/back-end block `0xf600000` (0x11f000) and `dpu-gpcsr` `0xf790000` (0xe004) in `/proc/iomem`; the device tree's `reg` shows these as `0x200000` / `0x390000` offsets under the display bus |
| Outputs | two MIPI DSI hosts (`verisilicon,dc9x00-mipi-dsi2h`), connector `gs-dsi0` |
| Power | four power domains (`dpu_dsi0_pd`, `dpu_dsi1_pd`, `dpu_fe0_pd`, `dpu_fe1_pd`); 30 IOMMU stream IDs (layers, blender, panel read/write) |
| Panels | `google,gs-dcsda` and `google,gs-dcsdb` (also `flea`/`fleb` variants), reset GPIO on `0x9e` pin 11, supplies `vci`, `vddi`, `vddd`; the notes report 1080 x 2424 for DCSDB |
| Implication | Whether the bootloader leaves the splash scanning out is the first thing to measure (read the DPU's enable/address registers from the shim; look for a framebuffer address and stride). If it does not survive, bring-up means power domains, DSI PHY, panel init commands and IOMMU. A scanout buffer address is also needed for `boot_args.Video`. |

## Touch and buttons

| Item | Value |
|---|---|
| Touch controller | `synaptics,tcm-spi` ("touchscreen@0") on the always-on SPI controller at `0xda2c000` (`google,spi`, DMA-capable, `num-cs 1`, CS GPIO on bank `0x363` pin 0x17) |
| Control lines | IRQ GPIO bank `0x363` pin 0x36, reset GPIO bank `0x9e` pin 0x11, supplies `avdd` / `vdd` with 200 ms power delay |
| Firmware | the Android driver loads `synaptics_4cs4.img` (and `_ba`, `_bb` variants) by panel ID (`panel_id_map`); the protocol is Synaptics TCM over SPI (documented upstream in the Linux `synaptics_tcm` driver) |
| Power key / volume | on the PMIC family (`max77779`) and GPIO banks; not yet traced |
| Other I2C/SPI devices on the same buses | `tps628600` regulator (I2C), NFC `st21nfc`/`st54spi`, a ToF sensor on `lsios_spi1`, not needed for the first boot |

## Display + touch + storage ordering suggestion

1. Measure what the bootloader leaves behind (read-only register reads from the shim): UFS HCS/link, dwc3 DSTS/DCTL, DPU enable and scanout address.
2. Pick the transport from those reads, then build it.
3. Display next (a framebuffer also gives a log channel), then touch over the AON SPI, then buttons and battery.


## Measured: what the bootloader leaves behind (2026-10-25, shim read-only MMIO probes 260-269)

Each value was read by the shim before XNU runs and returned through the reset cookie (low 30 bits). Android came back by itself every time.

| Register | Value | Meaning |
|---|---|---|
| UFS host `VER` (0x3c2d0008) | 0x0400 | UFSHCI 4.0; the block is powered and clocked |
| UFS host `HCS` (0x3c2d0030) | 0x0108 | UIC command ready; a power-mode status is reported; link is up |
| UFS host `HCE` (0x3c2d0034) | 0x3 | host controller **enabled** (HCE=1, clock gating on) |
| UFS host `CAP` (0x3c2d0000) | ...3c70f1f (top 2 bits not captured) | 32 transfer-request slots (NUTRS 0x1f) |
| USB wrapper (0x0a200000) | 0x0 | readable, all zero |
| dwc3 core `GSNPSID/DSTS/DCTL/DCFG/GCTL` (0x0a21c1xx, 0x0a21c7xx) | **Fabric Timeout** reset | the dwc3 core is not accessible after handoff: its clock or power domain is off, so a USB loader needs a full bring-up (power domain, clocks, resets, PHY) |

Conclusion: the **UFS route is much closer than staged USB**. The host controller is enabled with the link up, so a first read-only driver may only have to set up queues and issue READ commands, not initialise clocks/PHY. Next measurement: the doorbell and queue registers (MCQ mode), the LUN list (REPORT LUNS), and whether the IOMMU (`iommus = <0x82 0x8000>`) has to allow the DMA buffers.
