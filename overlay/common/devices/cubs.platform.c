/*
 * DRAFT ONLY: CUBS has no UEFI/GOP handoff yet; do not register or boot this platform.
 * Runtime values below were checked against the live Android FDT and /proc/iomem.
 * FD_BASE, FD_SIZE, PAYLOAD_BASE, and fb_base still require pre-OS UEFI measurements.
 */
static const struct platform platform_cubs = {
	.name = "cubs",
	/* Covers runtime-enumerated on-chip SoC MMIO below 1 GiB; it ends before System RAM. */
	.io_base = 0x04000000, .io_size = 0x3c000000,
	.gic_dist = 0x09228000, .gic_redist = 0x092a8000,
	.uart = 0,                                      /* CUBS exposes DW APB UART, not PL011 */
	.psci_hvc = 0,                                  /* live FDT: method = "smc" */
	.log_other_cpu = 1,
	.cores = 7, .core_shift = 8,                   /* MPIDRs: 0x000 through 0x600 */
	.small_cores = 0x03,                           /* CPU0/1 lowest capacity-dmips-mhz */
	.fb_base = 0x0,                                /* unknown until a CUBS GOP exists */
};
