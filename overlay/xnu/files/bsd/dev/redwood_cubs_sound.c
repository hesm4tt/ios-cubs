/*
 * The sink of /dev/redwood-audio on the Pixel: the PCM that iOS plays (48 kHz, 16-bit stereo) goes into a ring in the RAM Linux has reserved (PA 0xab2000000 + 0x1A00000)
 * where sndsrv on Android takes it and gives it to the app com.cubs.cam's SndService, which plays it with AudioTrack. Boot-arg cubs_sound=1.
 *   +0x0000 u32 magic "AUD1" (sndsrv writes it when it is up)   +0x0040 u32 wr, frames written by XNU   +0x0080 u32 rd, frames read by sndsrv
 *   +0x1000 the ring: RING_FRAMES frames of 4 bytes
 */
#include <kern/clock.h>
#include <kern/thread.h>
#include <kern/thread_call.h>
#include <libkern/libkern.h>
#include <mach/mach_types.h>
#include <pexpert/pexpert.h>
#include <sys/systm.h>
#include <vm/pmap.h>
#include <sys/redwood_audio.h>

extern void *io_map(vm_map_offset_t phys_addr, vm_size_t size, unsigned int flags, vm_prot_t prot, bool unmappable);
extern void FlushPoC_DcacheRegion(vm_offset_t va, unsigned length);

#define SND_PA          (0xab2000000ULL + 0x1A00000ULL)
#define RING_FRAMES     16384
#define SND_SIZE        (0x1000 + RING_FRAMES * 4)
#define SND_MAGIC       0x31445541u     /* "AUD1" */

static volatile uint8_t *cs_ring;
static uint32_t cs_wr;
static uint64_t cs_total, cs_dropped;

static uint32_t
cs_sink(const int16_t *frames, uint32_t count)
{
	volatile uint32_t *hd = (volatile uint32_t *)cs_ring;
	uint32_t rd, room, take, i;

	if (cs_ring == NULL) {
		return 0;
	}
	FlushPoC_DcacheRegion((vm_offset_t)cs_ring, 256);
	if (hd[0] != SND_MAGIC) {
		return 0;               /* nobody plays: dropped */
	}
	rd = hd[0x80 / 4];
	room = RING_FRAMES - (cs_wr - rd);
	take = count < room ? count : room;
	for (i = 0; i < take; i++) {
		((volatile uint32_t *)(cs_ring + 0x1000))[(cs_wr + i) % RING_FRAMES] = ((const uint32_t *)frames)[i];
	}
	if (take) {
		cs_wr += take;
		FlushPoC_DcacheRegion((vm_offset_t)(cs_ring + 0x1000), RING_FRAMES * 4);
		__asm__ volatile ("dsb sy" ::: "memory");
		hd[0x40 / 4] = cs_wr;
		FlushPoC_DcacheRegion((vm_offset_t)cs_ring, 256);
	}
	cs_total += take;
	cs_dropped += count - take;
	if ((cs_total & 0x1ffff) < take) {
		printf("sound: ring to Android: %llu frames taken, %llu dropped\n", cs_total, cs_dropped);
	}
	return take;
}

static thread_call_t cs_call;

static void
cs_start(__unused thread_call_param_t a, __unused thread_call_param_t b)
{
	cs_ring = (volatile uint8_t *)io_map(SND_PA, SND_SIZE, VM_WIMG_DEFAULT, VM_PROT_DEFAULT, false);
	if (cs_ring == NULL) {
		printf("sound: the ring to Android cannot be mapped\n");
		return;
	}
	FlushPoC_DcacheRegion((vm_offset_t)cs_ring, 256);
	cs_wr = ((volatile uint32_t *)cs_ring)[0x80 / 4];
	redwood_audio_set_sink("the ring to Android (sndsrv)", cs_sink);
	printf("sound: the ring to Android is the sink of /dev/redwood-audio\n");
}


/* cubs_hb=1: a heartbeat for Android to watch (PA 0xab2000000 + 0xFF2000: u32 "HBT1", u32 count, u64 mach_absolute_time), written from a timer every 100 ms */
static thread_call_t hb_call;
static volatile uint8_t *hb_page;
static uint32_t hb_count;
extern uint32_t cubs_cam_stat[8];

static void
hb_tick(__unused thread_call_param_t a, __unused thread_call_param_t b)
{
	volatile uint32_t *p;
	uint64_t t = mach_absolute_time(), deadline;

	if (hb_page == NULL) {
		hb_page = (volatile uint8_t *)io_map(0xab2000000ULL + 0xFF2000ULL, 0x1000, VM_WIMG_DEFAULT, VM_PROT_DEFAULT, false);
		printf("cubs_hb: heartbeat page mapped at %p\n", (void *)hb_page);
		if (hb_page == NULL) {
			clock_interval_to_deadline(1000, NSEC_PER_MSEC, &deadline);
			thread_call_enter_delayed(hb_call, deadline);
			return;
		}
	}
	p = (volatile uint32_t *)hb_page;
	hb_count++;
	p[1] = hb_count;
	p[2] = (uint32_t)t;
	p[3] = (uint32_t)(t >> 32);
	for (int i = 0; i < 8; i++) {
		p[4 + i] = cubs_cam_stat[i];
	}
	p[0] = 0x31544248u;
	FlushPoC_DcacheRegion((vm_offset_t)hb_page, 64);
	clock_interval_to_deadline(100, NSEC_PER_MSEC, &deadline);
	thread_call_enter_delayed(hb_call, deadline);
}

static void
hb_init(void)
{
	uint32_t on = 0;
	uint64_t deadline;

	if (!PE_parse_boot_argn("cubs_hb", &on, sizeof(on)) || !on) {
		return;
	}
	hb_call = thread_call_allocate(hb_tick, NULL);
	clock_interval_to_deadline(1000, NSEC_PER_MSEC, &deadline);
	thread_call_enter_delayed(hb_call, deadline);
}

void
redwood_cubs_sound_init(void)
{
	uint32_t on = 0;
	uint64_t deadline;

	hb_init();
	if (!PE_parse_boot_argn("cubs_sound", &on, sizeof(on)) || !on) {
		return;
	}
	cs_call = thread_call_allocate(cs_start, NULL);
	clock_interval_to_deadline(2000, NSEC_PER_MSEC, &deadline);
	thread_call_enter_delayed(cs_call, deadline);
}
