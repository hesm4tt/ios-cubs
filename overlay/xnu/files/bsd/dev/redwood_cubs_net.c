/*
 * The link of en0 on the Pixel: Ethernet frames carried through a shared-memory ring to a server on Android (netsrv), which answers ARP and DHCP,
 * and forwards the IPv4 traffic through a tun device and Android's own network (Wi-Fi or mobile data).
 *
 * The ring is in the RAM Linux has reserved for iOS (PA 0xab2000000, the span the GPU servers use), at +0x1000000:
 *   +0x0000  header: u32 magic "NET1" (written by netsrv when it is up); u32 xnu_up (written here)
 *   +0x0040  tx_prod (here)   +0x0080 tx_cons (netsrv)   +0x00C0 rx_prod (netsrv)   +0x0100 rx_cons (here)    (a cache line each)
 *   +0x1000  tx slots (iOS -> Android): NET_SLOTS of NET_SLOT bytes: u32 length, the frame
 *   +0x41000 rx slots (Android -> iOS)
 * Boot-arg cubs_net=1 turns it on. Called from redwood_net_init().
 */
#include <kern/clock.h>
#include <kern/thread.h>
#include <kern/thread_call.h>
#include <vm/pmap.h>
#include <libkern/libkern.h>
#include <mach/mach_types.h>
#include <pexpert/pexpert.h>
#include <sys/kpi_mbuf.h>
#include <sys/redwood_net.h>
#include <sys/systm.h>

extern void *io_map(vm_map_offset_t phys_addr, vm_size_t size, unsigned int flags, vm_prot_t prot, bool unmappable);
extern void FlushPoC_DcacheRegion(vm_offset_t va, unsigned length);

#define NET_PA          (0xab2000000ULL + 0x1000000ULL)
#define NET_SLOTS       128
#define NET_SLOT        2048
#define NET_TX          0x1000
#define NET_RX          0x41000
#define NET_SIZE        0x81000
#define NET_MAGIC       0x3154454eu     /* "NET1" */

static volatile uint8_t *cn_ring;
static uint32_t cn_tx_prod, cn_rx_cons;
static uint32_t cn_sent, cn_got, cn_full;

static inline volatile uint32_t *
cn_w(uint32_t off)
{
	return (volatile uint32_t *)(cn_ring + off);
}

static void
cn_dsb(void)
{
	__asm__ volatile ("dsb sy" ::: "memory");
}

static bool
cn_transmit(mbuf_t packet, size_t length)
{
	uint32_t cons, off;
	volatile uint8_t *slot;

	if (cn_ring == NULL || length > NET_SLOT - 4) {
		return false;
	}
	FlushPoC_DcacheRegion((vm_offset_t)cn_ring, 256);
	cons = *cn_w(0x80);
	if (cn_tx_prod - cons >= NET_SLOTS) {
		cn_full++;
		return false;
	}
	off = NET_TX + (cn_tx_prod % NET_SLOTS) * NET_SLOT;
	slot = cn_ring + off;
	if (mbuf_copydata(packet, 0, length, (void *)(slot + 4)) != 0) {
		return false;
	}
	*(volatile uint32_t *)slot = (uint32_t)length;
	cn_dsb();
	FlushPoC_DcacheRegion((vm_offset_t)slot, (unsigned)(length + 4));
	cn_dsb();
	cn_tx_prod++;
	*cn_w(0x40) = cn_tx_prod;
	cn_dsb();
	FlushPoC_DcacheRegion((vm_offset_t)cn_ring, 256);
	cn_sent++;
	return true;
}

static unsigned
cn_poll(void)
{
	unsigned n = 0;
	uint32_t prod;

	if (cn_ring == NULL) {
		return 0;
	}
	FlushPoC_DcacheRegion((vm_offset_t)cn_ring, 256);
	prod = *cn_w(0xC0);
	while (cn_rx_cons != prod && n < 64) {
		volatile uint8_t *slot = cn_ring + NET_RX + (cn_rx_cons % NET_SLOTS) * NET_SLOT;
		uint32_t length;

		FlushPoC_DcacheRegion((vm_offset_t)slot, NET_SLOT);
		length = *(volatile uint32_t *)slot;
		if (length >= 14 && length <= NET_SLOT - 4) {
			redwood_net_input((const uint8_t *)(slot + 4), length);
			cn_got++;
		}
		cn_rx_cons++;
		n++;
	}
	if (n) {
		*cn_w(0x100) = cn_rx_cons;
		cn_dsb();
		FlushPoC_DcacheRegion((vm_offset_t)cn_ring, 256);
	}
	return n;
}

static struct redwood_net_link cn_link = {
	.name = "the ring to Android (netsrv)",
	.address = { 0x02, 0x50, 0x58, 0x4c, 0x00, 0x02 },
	.wireless = false,
	.up = true,
	.transmit = cn_transmit,
	.poll = cn_poll,
};

static thread_call_t cn_call;

static void
cn_start(__unused thread_call_param_t p0, __unused thread_call_param_t p1)
{
	uint64_t deadline;

	if (cn_ring == NULL) {
		cn_ring = (volatile uint8_t *)io_map(NET_PA, NET_SIZE, VM_WIMG_DEFAULT, VM_PROT_DEFAULT, false);
		if (cn_ring == NULL) {
			printf("net: the ring to Android cannot be mapped\n");
			return;
		}
	}
	FlushPoC_DcacheRegion((vm_offset_t)cn_ring, 256);
	if (*cn_w(0) != NET_MAGIC) {
		/* netsrv is not up (yet): try again in a second */
		static unsigned said;

		if ((said++ % 10) == 0) {
			printf("net: the ring to Android: magic %#x (want %#x), words %#x %#x %#x\n", *cn_w(0), NET_MAGIC, *cn_w(4), *cn_w(0x40), *cn_w(0xC0));
		}
		clock_interval_to_deadline(1000, NSEC_PER_MSEC, &deadline);
		thread_call_enter_delayed(cn_call, deadline);
		return;
	}
	cn_tx_prod = *cn_w(0x40);
	cn_rx_cons = *cn_w(0xC0);
	*cn_w(0x100) = cn_rx_cons;
	*cn_w(4) = 1;
	cn_dsb();
	FlushPoC_DcacheRegion((vm_offset_t)cn_ring, 256);
	if (!redwood_net_attach(&cn_link)) {
		printf("net: no network interface (the ring)\n");
	}
}

void
redwood_cubs_net_init(void)
{
	uint32_t enabled = 0;
	uint64_t deadline;

	if (!PE_parse_boot_argn("cubs_net", &enabled, sizeof(enabled)) || !enabled) {
		return;
	}
	cn_call = thread_call_allocate(cn_start, NULL);
	clock_interval_to_deadline(1000, NSEC_PER_MSEC, &deadline);
	thread_call_enter_delayed(cn_call, deadline);
}
