/*
 * The microphone of iOS on the Pixel (boot-arg cubs_mic=1): /dev/redwood-mic, which RedwoodAudio.driver's "Codec" input (userland/src/audio_plugin.c) opens and reads
 * while iOS records (16-bit samples, one channel, 48 kHz; a read never waits and gives what has come, the plug-in fills the rest with silence). The samples come
 * from Android: micsrv there records the phone's microphone only while this device is open, into a ring in the RAM Linux has reserved (PA 0xab2000000 + 0x1A20000):
 *   +0x0000 u32 magic "MIC1" (micsrv writes it when it is up)   +0x0040 u32 ios_wants (written here: the device is open)   +0x0080 u32 wr, frames written by micsrv
 *   +0x1000 the ring: RING_FRAMES int16 samples
 * (redwood_mic.c's mic=4 makes the same device from the audio DSP of another phone; it must not be used together with this.)
 */
#include <kern/clock.h>
#include <kern/thread.h>
#include <kern/thread_call.h>
#include <libkern/libkern.h>
#include <mach/mach_types.h>
#include <miscfs/devfs/devfs.h>
#include <pexpert/pexpert.h>
#include <sys/conf.h>
#include <sys/systm.h>
#include <sys/uio.h>
#include <vm/pmap.h>

extern void *io_map(vm_map_offset_t phys_addr, vm_size_t size, unsigned int flags, vm_prot_t prot, bool unmappable);
extern void FlushPoC_DcacheRegion(vm_offset_t va, unsigned length);

#define MIC_PA          (0xab2000000ULL + 0x1A20000ULL)
#define RING_FRAMES     16384
#define MIC_SIZE        (0x1000 + RING_FRAMES * 2)
#define MIC_MAGIC       0x3143494du     /* "MIC1" */
#define RING_KEEP       1920            /* 40 ms: how far behind Android a reader is kept */
#define RING_MOST       4800            /* 100 ms: more waiting than this and the oldest is skipped */

static volatile uint8_t *cm_ring;
static uint32_t cm_rd;                  /* frames taken (the audio server is the one reader) */
static bool cm_primed;
static uint64_t cm_total, cm_skipped, cm_dry, cm_opens, cm_reads;
static int cm_peak;                     /* the loudest raw sample given since the last log line */

static void
cm_header_set(uint32_t off, uint32_t v)
{
	((volatile uint32_t *)cm_ring)[off / 4] = v;
	__asm__ volatile ("dsb sy" ::: "memory");
	FlushPoC_DcacheRegion((vm_offset_t)cm_ring, 256);
}

static uint32_t
cm_header_get(uint32_t off)
{
	FlushPoC_DcacheRegion((vm_offset_t)cm_ring, 256);
	return ((volatile uint32_t *)cm_ring)[off / 4];
}

static int
cm_open(__unused dev_t dev, __unused int flags, __unused int type, __unused struct proc *p)
{
	if (cm_ring == NULL) {
		return ENXIO;
	}
	cm_rd = cm_header_get(0x80);        /* only what is recorded from now on */
	cm_primed = false;
	cm_opens++;
	cm_header_set(0x40, 1);
	printf("mic: iOS opens the microphone (%llu)%s\n", cm_opens, cm_header_get(0) == MIC_MAGIC ? "" : ": micsrv on Android is not up");
	return 0;
}

static int
cm_close(__unused dev_t dev, __unused int flags, __unused int type, __unused struct proc *p)
{
	if (cm_ring != NULL) {
		cm_header_set(0x40, 0);
	}
	printf("mic: iOS closes the microphone: %llu frames given, %llu skipped, %llu reads short\n", cm_total, cm_skipped, cm_dry);
	return 0;
}

static int
cm_read(__unused dev_t dev, struct uio *uio, __unused int ioflag)
{
	uint32_t wr, avail, want;
	int error = 0;

	cm_reads++;
	if (cm_ring == NULL || uio_resid(uio) < 2 || cm_header_get(0) != MIC_MAGIC) {
		if (cm_reads <= 5) {
			printf("mic: read %llu: nothing (ring %p, resid %lld, magic %x)\n", cm_reads, (void *)cm_ring, (long long)uio_resid(uio),
			    cm_ring ? cm_header_get(0) : 0);
		}
		return 0;
	}
	wr = cm_header_get(0x80);
	want = (uint32_t)uio_resid(uio) / 2;
	avail = wr - cm_rd;
	if (avail > RING_FRAMES) {              /* lapped: start again */
		avail = 0;
		cm_rd = wr;
	}
	if (avail > RING_MOST) {
		cm_skipped += avail - RING_KEEP;
		cm_rd = wr - RING_KEEP;
		avail = RING_KEEP;
	}
	if (!cm_primed) {
		if (avail < RING_KEEP) {
			return 0;
		}
		cm_primed = true;
	}
	if (avail < want) {
		cm_dry++;
		cm_primed = false;
	}
	if (cm_reads <= 8 || (cm_reads % 400) == 0) {
		printf("mic: read %llu: want %u avail %u (wr %u rd %u) primed %d, given so far %llu, short %llu, peak %d\n", cm_reads, want, avail, wr, cm_rd,
		    cm_primed, cm_total, cm_dry, cm_peak);
		cm_peak = 0;
	}
	while (want > 0 && avail > 0 && error == 0) {
		uint32_t at = cm_rd % RING_FRAMES, n = want < avail ? want : avail;

		n = n < RING_FRAMES - at ? n : RING_FRAMES - at;
		FlushPoC_DcacheRegion((vm_offset_t)(cm_ring + 0x1000 + at * 2), n * 2);
		for (uint32_t i = 0; i < n; i++) {
			int v = ((volatile int16_t *)(cm_ring + 0x1000))[at + i];

			v = v < 0 ? -v : v;
			cm_peak = v > cm_peak ? v : cm_peak;
		}
		error = uiomove((caddr_t)(cm_ring + 0x1000 + at * 2), (int)(n * 2), uio);
		cm_rd += n;
		cm_total += n;
		want -= n;
		avail -= n;
	}
	return error;
}

static const struct cdevsw cm_cdevsw = {
	.d_open = cm_open, .d_close = cm_close, .d_read = cm_read, .d_write = eno_rdwrt,
	.d_ioctl = eno_ioctl, .d_stop = eno_stop, .d_reset = eno_reset, .d_select = eno_select,
	.d_mmap = eno_mmap, .d_strategy = eno_strat, .d_type = 0
};

static thread_call_t cm_call;

static void
cm_start(__unused thread_call_param_t a, __unused thread_call_param_t b)
{
	int major;

	cm_ring = (volatile uint8_t *)io_map(MIC_PA, MIC_SIZE, VM_WIMG_DEFAULT, VM_PROT_DEFAULT, false);
	if (cm_ring == NULL) {
		printf("mic: the ring to Android cannot be mapped\n");
		return;
	}
	cm_header_set(0x40, 0);
	major = cdevsw_add(-1, &cm_cdevsw);
	if (major < 0 || devfs_make_node(makedev(major, 0), DEVFS_CHAR, UID_ROOT, GID_WHEEL, 0666, "redwood-mic") == NULL) {
		printf("mic: /dev/redwood-mic cannot be made\n");
		cm_ring = NULL;
		return;
	}
	printf("mic: /dev/redwood-mic is the microphone of Android (ring at PA 0x%llx)\n", MIC_PA);
}

void
redwood_cubs_mic_init(void)
{
	uint32_t on = 0;
	uint64_t deadline;

	if (!PE_parse_boot_argn("cubs_mic", &on, sizeof(on)) || !on) {
		return;
	}
	cm_call = thread_call_allocate(cm_start, NULL);
	clock_interval_to_deadline(1500, NSEC_PER_MSEC, &deadline);
	thread_call_enter_delayed(cm_call, deadline);
}
