/*
 * Return-to-loader debug channel.
 *
 * On hardware without a serial port there is no way to get the kernel log
 * out. The XNU loader therefore leaves UEFI intact (no ExitBootServices) and
 * publishes the physical address of a return stub in /chosen/loader-return.
 * When the kernel has nothing more to do (panic, halt, timer) it collects its
 * message buffer, the panic buffer and any kprintf output, maps the stub 1:1
 * through TTBR0 and jumps to it with that log. The loader then restores the UEFI environment and writes
 * the log to storage.
 *
 * Only valid while the kernel does not drive hardware that UEFI also uses.
 */
#include <mach/mach_types.h>
#include <machine/atomic.h>
#include <kern/cpu_number.h>
#include <kern/debug.h>
#include <kern/startup.h>
#include <kern/thread_call.h>
#include <kern/clock.h>
#include <arm/cpu_internal.h>
#include <arm/machine_routines.h>
#include <arm64/psci_smp.h>
#include <arm64/proc_reg.h>
#include <pexpert/pexpert.h>
#include <pexpert/arm64/board_config.h>
#include <vm/vm_page.h>
#include <vm/vm_compressor.h>

/*
 * The console log handed back to the loader. A long session writes more than fits, and both
 * ends matter: the start of the boot is kept as it is, and of everything after it the most
 * recent part (a ring); room is left for what is appended on the way out (the kernel message
 * buffer, a panic's text). loader_log_linearize() puts the pieces in order before returning.
 */
#define LOADER_LOG_SIZE (1536 * 1024)
#define LOADER_LOG_HEAD (256 * 1024)
#define LOADER_LOG_RING (1024 * 1024)

#if defined(GENERIC_GIC_V3_IRQ)
extern void gic_v3_irq_quiesce(void);
extern void gic_v3_irq_cpu_shutdown(void);
#endif

void loader_log_putc(char c);
volatile uint32_t cubs_daif_bits;
volatile uint32_t cubs_gic_sample;
volatile uint32_t cubs_init_exit; /* CUBS probe: 0x10000 | wait status of process 1, once it exits */ /* CUBS probe: GIC/timer state at the IOBSD wait site */ /* CUBS probe: PSTATE.I sampled at numbered sites of early boot, bit (site-220) */
extern unsigned long debugger_panic_caller;
extern uint64_t cubs_undef_pc, cubs_undef_instr;
extern uint64_t cubs_exc_pc, cubs_exc_lr, cubs_exc_esr, cubs_exc_far;
extern const char *cubs_exc_msg;
extern const char *cubs_assert_file, *cubs_assert_expr;
extern int cubs_assert_line;
extern const char *debugger_panic_str;
void loader_return(void);
extern void redwood_adreno_quiesce(void);
extern void redwood_adreno_stop(void);
extern void redwood_adreno_minute(void);
extern void redwood_wifi_stop(void);
extern void redwood_wifi_quiesce(void);
extern void redwood_adsp_stop(void);
extern void redwood_adsp_quiesce(void);
extern void redwood_ddr_quiesce(void);
extern void redwood_haptic_quiesce(void);
extern void redwood_torch_quiesce(void);
extern void redwood_camera_quiesce(void);
extern void redwood_mic_quiesce(void);
extern void redwood_ufs_quiesce(void);
extern void redwood_var_save_on_return(void);   /* bsd/dev/redwood_ufs.c: the data volume into the flash */
void loader_checkpoint(uint64_t n);

/* Also referenced from the early exception vector in start.s. */
char     loader_log[LOADER_LOG_SIZE];
uint32_t loader_log_len;
static bool     loader_return_entered;

/* One L1 table and one L2 table are enough to map a single 2 MB block. */
static uint64_t loader_l1[512] __attribute__((aligned(4096)));
static uint64_t loader_l2[512] __attribute__((aligned(4096)));

static uint32_t loader_log_ring_at;      /* where the next character goes in the ring */
static bool     loader_log_wrapped;
static bool     loader_log_linear;       /* the pieces have been put in order: only appending from now on */
static char     loader_log_scratch[LOADER_LOG_RING];

/*
 * Characters come from every processor, and from interrupt handlers on top of whatever was
 * writing one. The lock is of the simplest kind, good from the first line of C code to the
 * last of a panic; whoever cannot have it for a long while (its holder is gone: a panic
 * inside this very function) goes ahead without it.
 */
static uint32_t loader_log_lock;

static void loader_log_put_locked(char c);

void
loader_log_putc(char c)
{
	uint64_t daif;
	bool locked = false;

	if (c == '\r') {
		return;
	}
	daif = __builtin_arm_rsr64("DAIF");
	__builtin_arm_wsr("DAIFSet", DAIFSC_IRQF | DAIFSC_FIQF);
	for (uint32_t tries = 0; !locked && tries < 10000000; tries++) {
		locked = os_atomic_cmpxchg(&loader_log_lock, 0, 1, acquire);
	}
	loader_log_put_locked(c);
	if (locked) {
		os_atomic_store(&loader_log_lock, 0, release);
	}
	__builtin_arm_wsr64("DAIF", daif);
}

/*
 * A whole line at once, under the lock: lines written from several processors at the same time
 * (tools/latency.py's "tl:" lines, a frame's on one and a touch's on another) are not mixed up.
 */
void loader_log_line(const char *line);

void
loader_log_line(const char *line)
{
	uint64_t daif;
	bool locked = false;

	daif = __builtin_arm_rsr64("DAIF");
	__builtin_arm_wsr("DAIFSet", DAIFSC_IRQF | DAIFSC_FIQF);
	for (uint32_t tries = 0; !locked && tries < 10000000; tries++) {
		locked = os_atomic_cmpxchg(&loader_log_lock, 0, 1, acquire);
	}
	for (; *line != 0; line++) {
		if (*line != '\r') {
			loader_log_put_locked(*line);
		}
	}
	if (locked) {
		os_atomic_store(&loader_log_lock, 0, release);
	}
	__builtin_arm_wsr64("DAIF", daif);
}

static void
loader_log_put_locked(char c)
{
	if (loader_log_linear || loader_log_len < LOADER_LOG_HEAD) {
		if (loader_log_len < LOADER_LOG_SIZE) {
			loader_log[loader_log_len++] = c;
		}
	} else {
		loader_log[LOADER_LOG_HEAD + loader_log_ring_at] = c;
		if (++loader_log_ring_at == LOADER_LOG_RING) {
			loader_log_ring_at = 0;
			loader_log_wrapped = true;
		}
		if (!loader_log_wrapped) {
			loader_log_len = LOADER_LOG_HEAD + loader_log_ring_at;
		}
	}
}

/* Oldest first: the head, a note about what was dropped, then the ring from its oldest character. */
static void
loader_log_linearize(void)
{
	static const char note[] = "\n\n[... the log between the first 256 KB and the last 1 MB was dropped ...]\n\n";
	uint32_t older = LOADER_LOG_RING - loader_log_ring_at, n = LOADER_LOG_HEAD;

	if (loader_log_linear) {
		return;
	}
	loader_log_linear = true;
	if (!loader_log_wrapped) {
		return;
	}
	__builtin_memcpy(loader_log_scratch, loader_log + LOADER_LOG_HEAD + loader_log_ring_at, older);
	__builtin_memcpy(loader_log_scratch + older, loader_log + LOADER_LOG_HEAD, loader_log_ring_at);
	/* the note takes the place of the oldest characters of the ring */
	__builtin_memcpy(loader_log + n, note, sizeof(note) - 1);
	n += sizeof(note) - 1;
	__builtin_memcpy(loader_log + n, loader_log_scratch + sizeof(note) - 1, LOADER_LOG_RING - (sizeof(note) - 1));
	loader_log_len = LOADER_LOG_HEAD + LOADER_LOG_RING;
}

/* Patched by the loader: { magic, PA of its return stub, checkpoint to stop at, PA - VA }. See start.s. */
extern uint64_t loader_stub_slot[4];

/*
 * For a loader that watches from another processor core while the kernel runs (it starts the
 * kernel on a core of its choice and stays on the first one): a sign of life, and where the log
 * is, so that the log of a kernel that hangs -- or dies before it has said a word through any
 * other channel -- is not lost with it. The loader finds this by its first word in the kernel
 * it has loaded. The addresses are the kernel's virtual ones, filled in by the linker and so
 * valid from the first instruction; the loader knows the distance to the physical ones.
 */
struct loader_live {
	uint64_t magic;                 /* "XNULIVE!" */
	uint64_t heartbeat;             /* goes up every HV_WDT_PET_SECONDS while the kernel is alive */
	const char *log;                /* loader_log */
	const uint32_t *log_len;        /* how much of it is in use */
	const uint32_t *log_ring_at;    /* where the ring part is being written */
	const bool *log_wrapped;        /* the ring has gone round */
	uint64_t log_head, log_ring;    /* sizes of the two parts */
	const uint64_t *recording;      /* loader_recording: { physical address, length } of a screen recording */
	volatile uint64_t stop;         /* the loader's to write: the host has asked for the run to end */
	uint64_t magic2;                /* "XNULIVE2": what follows is there (a loader may meet an older kernel) */
	const uint64_t *sound;          /* loader_sound: the same for a recording of the sound */
};

/*
 * A screen recording (the display driver makes one with boot-arg rec_secs): where it is, for the
 * loader to hand to the host once the kernel is back. { physical address, bytes, kernel address }.
 */
uint64_t loader_recording[3];
/* ... and of the sound (/dev/redwood-audio makes one with boot-arg rec_sound). */
uint64_t loader_sound[3];

struct loader_live loader_live = {
	.magic = 0x214556494c554e58ULL, .log = loader_log, .log_len = &loader_log_len, .log_ring_at = &loader_log_ring_at,
	.log_wrapped = &loader_log_wrapped, .log_head = LOADER_LOG_HEAD, .log_ring = LOADER_LOG_RING,
	.recording = loader_recording,
	.magic2 = 0x324556494c554e58ULL, .sound = loader_sound,
};

/* Valid from the first instruction of C code: does not depend on gVirtBase/gPhysBase being set up. */
static inline uint64_t
static_kvtophys(const void *va)
{
	return (uint64_t)va + loader_stub_slot[3];
}

/*
 * Jump to the loader's return stub. reason: 0 = orderly end, 2 = checkpoint.
 * Returns only if no loader is listening.
 */
static void
loader_jump(uint64_t reason, uint64_t code)
{
#if ARM_PGSHIFT == 12
	uint64_t stub = loader_stub_slot[1];
	uint64_t tcr, t0sz;
	uint32_t own_core = 0;

	if (stub == 0 || loader_return_entered) {
		return;
	}

	tcr = __builtin_arm_rsr64("TCR_EL1");
	t0sz = tcr & 0x3f;
	/* The TTBR0 walk must start at L1 (1 GB per entry) and reach the stub. */
	if (t0sz < 25 || t0sz > 33 || (stub >> (64 - t0sz)) != 0) {
		return;
	}
	loader_return_entered = true;
#if defined(GENERIC_GIC_V3_IRQ)
	gic_v3_irq_quiesce();
	/*
	 * With a core of its own (bootcpu=) the kernel does not go back into the loader's code on
	 * this processor: the stub leaves the log where the loader's core finds it and has the
	 * firmware switch this one off. It must go as the other cores do (psci_smp_cpu_off()), with
	 * nothing pending: after a panic the "stop" signal and the timer are.
	 */
	if (PE_parse_boot_argn("bootcpu", &own_core, sizeof(own_core))) {
		__builtin_arm_wsr64("CNTV_CTL_EL0", CNTV_CTL_EL0_IMASKED);
		gic_v3_irq_cpu_shutdown();
	}
#endif

	loader_l1[stub >> 30] = static_kvtophys(loader_l2) | ARM_TTE_TYPE_TABLE | ARM_TTE_VALID;
	loader_l2[(stub >> 21) & 0x1ff] = (stub & ~0x1fffffULL) | ARM_TTE_VALID | ARM_TTE_TYPE_BLOCK |
	    ARM_TTE_BLOCK_AF | ARM_TTE_BLOCK_SH(SH_OUTER_MEMORY) | ARM_TTE_BLOCK_AP(AP_RWNA) |
	    ARM_TTE_BLOCK_ATTRINDX(CACHE_ATTRINDX_WRITEBACK);

	/*
	 * The stub turns the MMU off, and on real hardware dirty cache lines do
	 * not survive that: write the log back to RAM first.
	 */
	for (uintptr_t p = (uintptr_t)loader_log & ~63UL; p < (uintptr_t)loader_log + loader_log_len; p += 64) {
		__asm__ volatile ("dc cvac, %0" : : "r" (p));
	}
	/* ... and a screen recording, and the note of where it is */
	for (uintptr_t p = loader_recording[2] & ~63UL; p < loader_recording[2] + loader_recording[1]; p += 64) {
		__asm__ volatile ("dc cvac, %0" : : "r" (p));
	}
	__asm__ volatile ("dc cvac, %0" : : "r" ((uintptr_t)loader_recording));
	__asm__ volatile ("dc cvac, %0" : : "r" ((uintptr_t)loader_recording + 16));
	for (uintptr_t p = loader_sound[2] & ~63UL; p < loader_sound[2] + loader_sound[1]; p += 64) {
		__asm__ volatile ("dc cvac, %0" : : "r" (p));
	}
	__asm__ volatile ("dc cvac, %0" : : "r" ((uintptr_t)loader_sound));
	__asm__ volatile ("dc cvac, %0" : : "r" ((uintptr_t)loader_sound + 16));
	__asm__ volatile ("dsb sy");

	register uint64_t r_ttbr0 __asm__("x0") = static_kvtophys(loader_l1);
	register uint64_t r_log __asm__("x2") = static_kvtophys(loader_log);
	register uint64_t r_len __asm__("x3") = loader_log_len;
	register uint64_t r_tcr __asm__("x4") = tcr;
	register uint64_t r_stub __asm__("x5") = stub;
	register uint64_t r_reason __asm__("x6") = reason;
	register uint64_t r_code __asm__("x7") = code;

	__asm__ volatile (
                "msr DAIFSet, #0xf\n"
                "bic x4, x4, #0x80\n"           /* TCR_EL1.EPD0: allow TTBR0 walks */
                "msr TCR_EL1, x4\n"
                "msr TTBR0_EL1, x0\n"
                "isb\n"
                "tlbi vmalle1\n"
                "dsb sy\n"
                "isb\n"
                "mov x0, x2\n"
                "mov x1, x3\n"
                "mov x2, x6\n"
                "mov x3, x7\n"
                "br x5\n"
                : : "r" (r_ttbr0), "r" (r_log), "r" (r_len), "r" (r_tcr), "r" (r_stub), "r" (r_reason), "r" (r_code));
	__builtin_unreachable();
#else
	(void)reason; (void)code;
#endif /* ARM_PGSHIFT == 12 */
}

extern char *debug_buf_base, *debug_buf_ptr;

/* bsd/sys/msgbuf.h (not includable from osfmk) */
struct msgbuf {
	int   msg_magic;
	int   msg_size;
	int   msg_bufx;         /* write pointer */
	int   msg_bufr;         /* read pointer */
	char *msg_bufc;         /* buffer */
};
extern struct msgbuf *msgbufp;

static void
loader_log_puts(const char *s)
{
	for (; *s; s++) {
		loader_log_putc(*s);
	}
}

/*
 * Everything printf()/IOLog()/os_log wrote ends up in the kernel message
 * buffer (what dmesg shows), whether or not a console displayed it.
 */
static void
loader_log_append_msgbuf(void)
{
	struct msgbuf *mb = msgbufp;

	if (mb == NULL || mb->msg_bufc == NULL || mb->msg_size <= 0 || mb->msg_bufx < 0 || mb->msg_bufx > mb->msg_size) {
		return;
	}
	loader_log_puts("\n--- kernel message buffer ---\n");
	/* oldest data first: [bufx, size) is only meaningful once the buffer has wrapped */
	for (int pass = 0; pass < 2; pass++) {
		int from = pass == 0 ? mb->msg_bufx : 0;
		int to = pass == 0 ? mb->msg_size : mb->msg_bufx;
		for (int i = from; i < to; i++) {
			if (mb->msg_bufc[i] != 0) {
				loader_log_putc(mb->msg_bufc[i]);
			}
		}
	}
}


/*
 * CUBS: with boot-arg cubs_logdump=1 the log is written to a spare area of UFS LUN 0 (modem_b tail,
 * LBA 950000) before the reset. The shim left the host controller running; this only issues WRITE(10).
 */
#define CUBS_LOG_LBA 950000ULL
struct cubs_utrd { volatile uint32_t dw0, dw1, dw2, dw3, ucdba, ucdbau, resp, prdt; };
static struct cubs_utrd cubs_log_utrl[32] __attribute__((aligned(1024)));
static struct {
	volatile uint8_t cmd[512];
	volatile uint8_t resp[512];
	volatile struct { uint32_t lo, hi, rsvd, dbc; } prdt[8];
} cubs_log_ucd __attribute__((aligned(128)));
static uint8_t cubs_log_hdr[4096] __attribute__((aligned(4096)));
static uint64_t cubs_log_pa_override;

static void
cubs_dcache_flush(const void *p, size_t n)
{
	for (uintptr_t a = (uintptr_t)p & ~63UL; a < (uintptr_t)p + n; a += 64) {
		__asm__ volatile ("dc civac, %0" : : "r" (a) : "memory");
	}
	__asm__ volatile ("dsb sy" ::: "memory");
}

static int
cubs_log_ufs_write(volatile uint32_t *r, uint64_t lba, uint32_t blocks, const void *buf)
{
	static uint8_t tag;
	uint32_t len = blocks * 4096;
	volatile uint8_t *c = cubs_log_ucd.cmd;
	for (unsigned i = 0; i < sizeof(cubs_log_ucd); i++) {
		((volatile uint8_t *)&cubs_log_ucd)[i] = 0;
	}
	for (unsigned i = 0; i < 8; i++) {
		((volatile uint32_t *)&cubs_log_utrl[0])[i] = 0;
	}
	c[0] = 0x01; c[1] = 0x20; c[2] = 0; c[3] = ++tag;
	c[12] = len >> 24; c[13] = len >> 16; c[14] = len >> 8; c[15] = len;
	c[16] = 0x2a;
	c[18] = lba >> 24; c[19] = lba >> 16; c[20] = lba >> 8; c[21] = lba;
	c[23] = blocks >> 8; c[24] = blocks;
	uint64_t ucd_pa = static_kvtophys(&cubs_log_ucd);
	uint64_t b = cubs_log_pa_override ? cubs_log_pa_override : static_kvtophys(buf);
	cubs_log_utrl[0].dw0 = (1u << 28) | (1u << 25) | (1u << 24);
	cubs_log_utrl[0].dw2 = 0x0f;
	cubs_log_utrl[0].ucdba = (uint32_t)ucd_pa;
	cubs_log_utrl[0].ucdbau = (uint32_t)(ucd_pa >> 32);
	cubs_log_utrl[0].resp = (512u / 4) << 16 | (512u / 4);
	cubs_log_ucd.prdt[0].lo = (uint32_t)b;
	cubs_log_ucd.prdt[0].hi = (uint32_t)(b >> 32);
	cubs_log_ucd.prdt[0].dbc = len - 1;
	cubs_log_utrl[0].prdt = (1024u / 4) << 16 | 1;
	cubs_dcache_flush((const void *)&cubs_log_ucd, sizeof(cubs_log_ucd));
	cubs_dcache_flush((const void *)cubs_log_utrl, sizeof(cubs_log_utrl));
	__asm__ volatile ("dsb sy" ::: "memory");
	r[0x58 / 4] = 1;
	uint64_t freq = __builtin_arm_rsr64("CNTFRQ_EL0"), t0 = __builtin_arm_rsr64("CNTVCT_EL0");
	while (r[0x58 / 4] & 1) {
		if (__builtin_arm_rsr64("CNTVCT_EL0") - t0 > freq) {
			r[0x5c / 4] = ~1u;
			return 1;
		}
	}
	cubs_dcache_flush((const void *)&cubs_log_ucd, sizeof(cubs_log_ucd));
	cubs_dcache_flush((const void *)cubs_log_utrl, sizeof(cubs_log_utrl));
	if ((cubs_log_utrl[0].dw2 & 0xff) != 0) {
		return 2;
	}
	if (cubs_log_ucd.resp[0] != 0x21) {
		return 3;
	}
	return cubs_log_ucd.resp[7] ? 4 : 0;
}

static void
cubs_log_hdr_write(volatile uint32_t *r, uint32_t state, uint32_t len, uint32_t blocks)
{
	for (unsigned i = 0; i < sizeof(cubs_log_hdr); i++) {
		cubs_log_hdr[i] = 0;
	}
	memcpy(cubs_log_hdr, "CUBSLOG1", 8);
	memcpy(cubs_log_hdr + 8, &len, 4);
	memcpy(cubs_log_hdr + 12, &blocks, 4);
	memcpy(cubs_log_hdr + 16, &state, 4);
	cubs_dcache_flush(cubs_log_hdr, sizeof(cubs_log_hdr));
	for (int t = 0; t < 4 && cubs_log_ufs_write(r, CUBS_LOG_LBA, 1, cubs_log_hdr); t++) {
	}
}

static void
cubs_dump_log_to_ufs(void)
{
	uint32_t arg = 0;
	if (!PE_parse_boot_argn("cubs_logdump", &arg, sizeof(arg)) || arg == 0) {
		return;
	}
	volatile uint32_t *r = (volatile uint32_t *)ml_io_map(0x3c2d0000UL, 0x1000);
	if (r == NULL || !(r[0x34 / 4] & 1) || r[0x58 / 4]) {
		return;
	}
	r[0x60 / 4] = 0;
	uint64_t list = static_kvtophys(cubs_log_utrl);
	r[0x50 / 4] = (uint32_t)list;
	r[0x54 / 4] = (uint32_t)(list >> 32);
	r[0x60 / 4] = 1;
	uint32_t len = loader_log_len;
	if (len > LOADER_LOG_SIZE) {
		len = LOADER_LOG_SIZE;
	}
	uint32_t blocks = (len + 4095) / 4096;
	cubs_dcache_flush(loader_log, (size_t)blocks * 4096);
	cubs_log_hdr_write(r, 1, len, blocks);
	uint32_t done = 0, ok = 1;
	while (done < blocks) {
		uint32_t c = blocks - done > 32 ? 32 : blocks - done, t = 0;
		while (cubs_log_ufs_write(r, CUBS_LOG_LBA + 1 + done, c, loader_log + (size_t)done * 4096)) {
			if (++t >= 4) {
				ok = 0;
				break;
			}
		}
		if (!ok) {
			break;
		}
		done += c;
	}
	cubs_log_hdr_write(r, ok ? 2 : 3, len, blocks);
	/* boot-arg cubs_fbdump=1: the RAM framebuffer (physical, from boot_args.Video) after the log at CUBS_LOG_LBA + 500 */
	if (ok && PE_parse_boot_argn("cubs_fbdump", &arg, sizeof(arg)) && arg && PE_state.video.v_baseAddr) {
		uint32_t fbblocks = (uint32_t)(((uint64_t)PE_state.video.v_rowBytes * PE_state.video.v_height + 4095) / 4096), d = 0;
		while (d < fbblocks) {
			uint32_t c = fbblocks - d > 32 ? 32 : fbblocks - d, t = 0;
			cubs_log_pa_override = PE_state.video.v_baseAddr + (uint64_t)d * 4096;
			while (cubs_log_ufs_write(r, CUBS_LOG_LBA + 500 + d, c, NULL)) {
				if (++t >= 4) {
					break;
				}
			}
			if (t >= 4) {
				break;
			}
			d += c;
		}
		cubs_log_pa_override = 0;
	}
}

/* CUBS probe: every thread's state, wait event and continuation, printed at the deadline */
extern queue_head_t threads;
void cubs_dump_threads(void);
void
cubs_dump_threads(void)
{
	thread_t th;
	uint32_t n = 0;
	queue_iterate(&threads, th, thread_t, threads) {
		void *bsd = get_bsdtask_info(th->t_tro->tro_task);
		printf("CUBS th: pid %d th %p state 0x%x ev %#llx cont %p pri %d\n", bsd ? proc_pid(bsd) : -1, th, th->state,
		    (uint64_t)th->wait_event, (void *)th->continuation, th->sched_pri);
		if (++n > 600) {
			break;
		}
	}
}

#include <arm/thread.h>
#include <vm/vm_map.h>
#include <vm/vm_shared_region.h>
#include <string.h>
extern char *proc_name_address(struct proc *p);
void cubs_dump_user(void);
void
cubs_dump_user(void)
{
	thread_t th;
	queue_iterate(&threads, th, thread_t, threads) {
		task_t task = get_threadtask(th);
		struct proc *p = get_bsdtask_info(task);
		const arm_saved_state_t *st;
		const char *nm;
		uint64_t ra[20], fp, fr[2];
		uint32_t slide = 0, i, nf = 0;
		vm_shared_region_t region;
		vm_map_t old;
		if (task == kernel_task || p == NULL) {
			continue;
		}
		nm = proc_name_address(p);
		if (strncmp(nm, "SpringBoard", 11) && strncmp(nm, "backboardd", 10)) {
			continue;
		}
		st = get_user_regs(th);
		if (st == NULL || !is_saved_state64(st)) {
			continue;
		}
		region = vm_shared_region_get(task);
		if (region != NULL) {
			slide = region->sr_slide;
			vm_shared_region_deallocate(region);
		}
		fp = (uint64_t)get_saved_state_reg(st, 29);
		old = vm_map_switch(task->map);
		for (i = 0; i < 20; i++) {
			if (fp < 0x100000000ULL || (fp & 7) || copyin((user_addr_t)fp, fr, 16)) {
				break;
			}
			ra[nf++] = fr[1] & 0x7fffffffffULL;
			fp = fr[0];
		}
		vm_map_switch(old);
		printf("CUBS ut: %s[%d] th %p st 0x%x slide 0x%x pc 0x%llx lr 0x%llx sp 0x%llx\n", nm, proc_pid(p), th, th->state, slide,
		    (unsigned long long)get_saved_state_pc(st), (unsigned long long)get_saved_state_lr(st), (unsigned long long)get_saved_state_sp(st));
		for (i = 0; i < nf; i++) {
			printf("CUBS uf: %s[%d] th %p #%u 0x%llx\n", nm, proc_pid(p), th, i, (unsigned long long)ra[i]);
		}
	}
}


extern void delay_for_interval(uint32_t interval, uint32_t scale_factor);

extern void delay_for_interval(uint32_t interval, uint32_t scale_factor);

static const uint32_t cubs_mbx[96][4] = {
	{ 0x00000100u, 0x00000000u, 0x00000000u, 0x00000000u },
	{ 0xa0010014u, 0x00000000u, 0x00000000u, 0x00000000u },
	{ 0xa0020014u, 0x10000000u, 0x00000000u, 0x00000000u },
	{ 0xa0030014u, 0x414dffffu, 0x70737973u, 0x0000006du },
	{ 0xa0040014u, 0x4086ffffu, 0x65696c63u, 0x0073746eu },
	{ 0xa0050014u, 0x4164ffffu, 0x00316d76u, 0x00000000u },
	{ 0xa0060014u, 0x4158ffffu, 0x64727561u, 0x762e7073u },
	{ 0xa0070014u, 0x71580003u, 0x00000000u, 0x00000000u },
	{ 0xa0080014u, 0x4158ffffu, 0x73736f61u, 0x2e67705fu },
	{ 0xa0090014u, 0x71580002u, 0x00000000u, 0x00000000u },
	{ 0xa00a0014u, 0x4158ffffu, 0x65646f63u, 0x70335f63u },
	{ 0xa00b0014u, 0x71580005u, 0x00000000u, 0x00000000u },
	{ 0xa00c0014u, 0x4158ffffu, 0x61757043u, 0x70476363u },
	{ 0xa00d0014u, 0x7158003fu, 0x00000000u, 0x00000000u },
	{ 0xa0010014u, 0x4158ffffu, 0x2e757064u, 0x00000076u },
	{ 0xa0020014u, 0x71580008u, 0x00000000u, 0x00000000u },
	{ 0xa0030014u, 0x4158ffffu, 0x42757044u, 0x00762e65u },
	{ 0xa0040014u, 0x71580027u, 0x00000000u, 0x00000000u },
	{ 0xa0050014u, 0x4158ffffu, 0x46757044u, 0x762e3065u },
	{ 0xa0060014u, 0x71580028u, 0x00000000u, 0x00000000u },
	{ 0xa0070014u, 0x4158ffffu, 0x46757044u, 0x762e3165u },
	{ 0xa0080014u, 0x71580029u, 0x00000000u, 0x00000000u },
	{ 0xa0090014u, 0x4158ffffu, 0x44757044u, 0x2e306973u },
	{ 0xa00a0014u, 0x7158002au, 0x00000000u, 0x00000000u },
	{ 0xa00b0014u, 0x4158ffffu, 0x44757044u, 0x2e316973u },
	{ 0xa00c0014u, 0x7158002bu, 0x00000000u, 0x00000000u },
	{ 0xa00d0014u, 0x4158ffffu, 0x44757044u, 0x762e3070u },
	{ 0xa0010014u, 0x7158002cu, 0x00000000u, 0x00000000u },
	{ 0xa0020014u, 0x4158ffffu, 0x2e643267u, 0x00000076u },
	{ 0xa0030014u, 0x7158000eu, 0x00000000u, 0x00000000u },
	{ 0xa0040014u, 0x4158ffffu, 0x43643247u, 0x2e65726fu },
	{ 0xa0050014u, 0x7158003cu, 0x00000000u, 0x00000000u },
	{ 0xa0060014u, 0x4158ffffu, 0x2e766367u, 0x00000076u },
	{ 0xa0070014u, 0x7158000fu, 0x00000000u, 0x00000000u },
	{ 0xa0080014u, 0x4158ffffu, 0x2e757067u, 0x00000076u },
	{ 0xa0090014u, 0x71580017u, 0x00000000u, 0x00000000u },
	{ 0xa00a0014u, 0x4158ffffu, 0x6f697368u, 0x762e6e5fu },
	{ 0xa00b0014u, 0x71580019u, 0x00000000u, 0x00000000u },
	{ 0xa00c0014u, 0x4158ffffu, 0x6f697348u, 0x6273554eu },
	{ 0xa00d0014u, 0x7158002du, 0x00000000u, 0x00000000u },
	{ 0xa0010014u, 0x4158ffffu, 0x6f697348u, 0x6273554eu },
	{ 0xa0020014u, 0x5158002du, 0x2e777350u, 0x00000076u },
	{ 0xa0030014u, 0x7158002eu, 0x00000000u, 0x00000000u },
	{ 0xa0040014u, 0x4158ffffu, 0x6f697348u, 0x7562454eu },
	{ 0xa0050014u, 0x7158002fu, 0x00000000u, 0x00000000u },
	{ 0xa0060014u, 0x4158ffffu, 0x6f697348u, 0x2e70444eu },
	{ 0xa0070014u, 0x71580030u, 0x00000000u, 0x00000000u },
	{ 0xa0080014u, 0x4158ffffu, 0x6f697348u, 0x4132554eu },
	{ 0xa0090014u, 0x71580031u, 0x00000000u, 0x00000000u },
	{ 0xa00a0014u, 0x4158ffffu, 0x6f697348u, 0x4132554eu },
	{ 0xa00b0014u, 0x51580031u, 0x73507875u, 0x00762e77u },
	{ 0xa00c0014u, 0x71580032u, 0x00000000u, 0x00000000u },
	{ 0xa00d0014u, 0x4158ffffu, 0x6f697368u, 0x762e735fu },
	{ 0xa0010014u, 0x7158001au, 0x00000000u, 0x00000000u },
	{ 0xa0020014u, 0x4158ffffu, 0x6f697348u, 0x73665553u },
	{ 0xa0030014u, 0x51580033u, 0x70657250u, 0x0000762eu },
	{ 0xa0040014u, 0x71580035u, 0x00000000u, 0x00000000u },
	{ 0xa0060014u, 0x4158ffffu, 0x6f697348u, 0x73665553u },
	{ 0xa0070014u, 0x71580033u, 0x00000000u, 0x00000000u },
	{ 0xa0090014u, 0x4158ffffu, 0x6f697348u, 0x2e645353u },
	{ 0xa00a0014u, 0x71580034u, 0x00000000u, 0x00000000u },
	{ 0xa00b0014u, 0x4158ffffu, 0x66707369u, 0x00762e65u },
	{ 0xa00c0014u, 0x7158001cu, 0x00000000u, 0x00000000u },
	{ 0xa00d0014u, 0x4158ffffu, 0x66707349u, 0x726f4365u },
	{ 0xa0010014u, 0x71580040u, 0x00000000u, 0x00000000u },
	{ 0xa0020014u, 0x4158ffffu, 0x66707349u, 0x726f4365u },
	{ 0xa0030014u, 0x51580040u, 0x762e3165u, 0x00000000u },
	{ 0xa0040014u, 0x71580041u, 0x00000000u, 0x00000000u },
	{ 0xa0050014u, 0x4158ffffu, 0x66707349u, 0x726f4365u },
	{ 0xa0060014u, 0x51580040u, 0x762e3265u, 0x00000000u },
	{ 0xa0070014u, 0x71580042u, 0x00000000u, 0x00000000u },
	{ 0xa0080014u, 0x4158ffffu, 0x66707349u, 0x69734365u },
	{ 0xa0090014u, 0x71580043u, 0x00000000u, 0x00000000u },
	{ 0xa00a0014u, 0x4158ffffu, 0x62707369u, 0x00762e65u },
	{ 0xa00b0014u, 0x7158001bu, 0x00000000u, 0x00000000u },
	{ 0xa00c0014u, 0x4158ffffu, 0x6f69736cu, 0x762e655fu },
	{ 0xa00d0014u, 0x7158001du, 0x00000000u, 0x00000000u },
	{ 0xa0010014u, 0x4158ffffu, 0x6f69734cu, 0x696c4345u },
	{ 0xa0020014u, 0x71580036u, 0x00000000u, 0x00000000u },
	{ 0xa0030014u, 0x4158ffffu, 0x6f69736cu, 0x762e735fu },
	{ 0xa0040014u, 0x7158001eu, 0x00000000u, 0x00000000u },
	{ 0xa0050014u, 0x4158ffffu, 0x6f69734cu, 0x696c4353u },
	{ 0xa0060014u, 0x71580037u, 0x00000000u, 0x00000000u },
	{ 0xa0080014u, 0x4158ffffu, 0x65696370u, 0x0000762eu },
	{ 0xa0090014u, 0x71580020u, 0x00000000u, 0x00000000u },
	{ 0xa00a0014u, 0x4158ffffu, 0x65696350u, 0x2e706f54u },
	{ 0xa00b0014u, 0x7158003au, 0x00000000u, 0x00000000u },
	{ 0xa00c0014u, 0x4158ffffu, 0x65696350u, 0x6c727443u },
	{ 0xa00d0014u, 0x71580038u, 0x00000000u, 0x00000000u },
	{ 0xa0010014u, 0x4158ffffu, 0x65696350u, 0x6c727443u },
	{ 0xa0020014u, 0x51580038u, 0x00762e31u, 0x00000000u },
	{ 0xa0030014u, 0x71580039u, 0x00000000u, 0x00000000u },
	{ 0xa0040014u, 0x4158ffffu, 0x2e757074u, 0x00000076u },
	{ 0xa0050014u, 0x71580021u, 0x00000000u, 0x00000000u },
	{ 0xa0060014u, 0x4158ffffu, 0x736d654du, 0x61744473u },
	{ 0xa0070014u, 0x7158003du, 0x00000000u, 0x00000000u },
};
#define CUBS_MBX_N 96

static volatile uint32_t *cubs_w1;
static uint32_t cubs_wc, cubs_wr;

static void cubs_wdt_feed(void)
{
	if (cubs_w1 != NULL && (cubs_wc & 1)) {
		cubs_w1[4] = 0xc0ffee;
		cubs_w1[3] = cubs_wr;
		cubs_w1[4] = 0;
	}
}

static unsigned cubs_mba_send(volatile uint32_t *rq, volatile uint32_t *rs, unsigned *si, const uint32_t m[4], unsigned want)
{
	volatile uint32_t *w = rq + (0x100 + 0x10 * (*si & 7)) / 4;
	unsigned got = 0, tx = 0, ms;
	w[0] = m[0]; w[1] = m[1]; w[2] = m[2]; w[3] = m[3];
	__asm__ volatile ("dsb sy; isb" ::: "memory");
	rq[0] = 1;
	for (ms = 0; ms < 200; ms++) {
		uint32_t a8 = rq[2], r8 = rs[2];
		cubs_wdt_feed();
		if (a8 & 0x100) {
			rq[2] = 0x100;
			(void)rq[4];
			tx = 1;
		}
		if (r8 & 1) {
			volatile uint32_t t0;
			unsigned o;
			for (o = 0x100; o < 0x140; o += 4) {
				t0 = rs[o / 4];
			}
			(void)t0;
			rs[2] = 1;
			got++;
		}
		if (got >= want && tx) {
			break;
		}
		delay_for_interval(1000, 1000);
	}
	return got;
}

static void cubs_mark(const char *n, unsigned off)
{
	unsigned k;
	loader_log_puts("MARK ");
	loader_log_puts(n);
	loader_log_puts(" 0x");
	for (k = 0; k < 6; k++) {
		loader_log_putc("0123456789abcdef"[(off >> (20 - 4 * k)) & 0xf]);
	}
	loader_log_putc(10);
	cubs_dump_log_to_ufs();
}

static void cubs_dump_block(const char *n, uint64_t pa, unsigned words)
{
	volatile uint32_t *b = (volatile uint32_t *)ml_io_map(pa, 0x1000);
	unsigned o;
	printf("CUBS blk %s pa 0x%llx\n", n, pa);
	for (o = 0; o < words; o++) {
		uint32_t v;
		if (o % 16 == 0) {
			cubs_mark(n, o * 4);
		}
		v = b[o];
		if (v) {
			printf("CUBS blk %s 0x%x 0x%x\n", n, o * 4, v);
		}
	}
	printf("CUBS blk %s end\n", n);
}

#include "cubs_replay.h"

static struct { uint64_t pa; uint32_t sz; volatile uint8_t *va; } cubs_rmap[] = {
	{ 0xf600000ULL, 0x11f000, NULL }, { 0xf7c0000ULL, 0x18000, NULL }, { 0xf7e0000ULL, 0x18000, NULL },
	{ 0xf7d8000ULL, 0x1000, NULL }, { 0xf7f8000ULL, 0x1000, NULL }, { 0xf46e000ULL, 0x1000, NULL },
	{ 0x3bcd2000ULL, 0x1000, NULL }, { 0xf371000ULL, 0x1000, NULL }, { 0x3a1ce000ULL, 0x1000, NULL },
	{ 0x3a1cd000ULL, 0x1000, NULL }, { 0x3a0fc000ULL, 0x1000, NULL }, { 0x3a0fd000ULL, 0x1000, NULL },
	{ 0xf190000ULL, 0x1000, NULL },
	{ 0x23801000ULL, 0x1000, NULL }, { 0xeb60000ULL, 0x2000, NULL }, { 0x3bdcb000ULL, 0x1000, NULL },
};

static uint32_t cubs_lim = 1000;

static volatile uint8_t *cubs_rva(uint64_t pa)
{
	unsigned k;
	for (k = 0; k < sizeof(cubs_rmap) / sizeof(cubs_rmap[0]); k++) {
		if (pa >= cubs_rmap[k].pa && pa < cubs_rmap[k].pa + cubs_rmap[k].sz) {
			return cubs_rmap[k].va + (pa - cubs_rmap[k].pa);
		}
	}
	return NULL;
}

void
cubs_dpu_probe(void) /* cubs_mba_probe_v21: boot message replay + display wake replay */
{
	volatile uint32_t *rq = (volatile uint32_t *)ml_io_map(0xea60000ULL, 0x1000);
	volatile uint32_t *rs = (volatile uint32_t *)ml_io_map(0xea61000ULL, 0x1000);
	unsigned i, c, si = 0, resp = 0, nmsg = 0, nresp = 0, nw = 0, nskip = 0;
	volatile uint32_t *cl[2] = { rq, rs };
	uint32_t cseq = 0;

	if (rq == NULL || rs == NULL) {
		printf("CUBS mba map failed\n");
		return;
	}
	cubs_w1 = (volatile uint32_t *)ml_io_map(0x200c5000UL, 0x1000);
	cubs_wc = cubs_w1[2];
	cubs_wr = cubs_w1[3];
	for (i = 0; i < sizeof(cubs_rmap) / sizeof(cubs_rmap[0]); i++) {
		cubs_rmap[i].va = (volatile uint8_t *)ml_io_map(cubs_rmap[i].pa, cubs_rmap[i].sz);
	}
	for (c = 0; c < 2; c++) {
		cl[c][1] = cl[c][1] & 0xfefefeffu;
		cl[c][2] = cl[c][2] & 0x101u;
	}
	rs[2] = 1;
	for (c = 0; c < 2; c++) {
		cl[c][1] = cl[c][1] | 0x01010100u;
	}
	__asm__ volatile ("dsb sy; isb" ::: "memory");
	for (i = 0; i < CUBS_BOOT_N; i++) {
		uint32_t mm[4];
		mm[0] = cubs_boot[i][0]; mm[1] = cubs_boot[i][1]; mm[2] = cubs_boot[i][2]; mm[3] = cubs_boot[i][3];
		if (i > 0) {
			cseq = cseq % 13 + 1;
			mm[0] = (mm[0] & 0xff00ffffu) | (cseq << 16);
		}
		resp += cubs_mba_send(rq, rs, &si, mm, i ? 1 : 0);
		if (i > 0) {
			si++;
		}
	}
	printf("CUBS mba boot replay responses %u of %u\n", resp, CUBS_BOOT_N - 1);
	cubs_mark("boot-replay-done", resp);
	{
		uint32_t lim = 1000;
		(void)PE_parse_boot_argn("cubs_deadline", &lim, sizeof(lim));
		cseq += 0;
		cubs_lim = lim;
	}
	for (i = 0; i < CUBS_WAKE_N; i++) {
		if (cubs_wake[i].k == 1 && nmsg >= cubs_lim) {
			break;
		}
		if ((i & 15) == 0) {
			cubs_wdt_feed();
		}
		if (cubs_wake[i].us) {
			delay_for_interval(cubs_wake[i].us, 1000000);
		}
		if (cubs_wake[i].k == 1) {
			uint32_t mm[4];
			unsigned want = 1;
			mm[0] = (uint32_t)cubs_wake[i].a; mm[1] = (uint32_t)(cubs_wake[i].a >> 32); mm[2] = cubs_wake[i].v; mm[3] = cubs_wake[i].w;
			cseq = cseq % 13 + 1;
			mm[0] = (mm[0] & 0xff00ffffu) | (cseq << 16);
			if ((mm[1] >> 16) == 0x8158) {
				want = 2;
			}
			nresp += cubs_mba_send(rq, rs, &si, mm, want);
			si++;
			nmsg++;
			if (nmsg == 8 || nmsg == 20 || nmsg == 40) {
				cubs_mark("wake-msg", nmsg);
			}
		} else {
			volatile uint8_t *va = cubs_rva(cubs_wake[i].a);
			if (va == NULL) {
				nskip++;
				continue;
			}
			if (cubs_wake[i].w == 64) {
				*(volatile uint64_t *)va = cubs_wake[i].v;
			} else {
				*(volatile uint32_t *)va = cubs_wake[i].v;
			}
			nw++;
			if ((nw & 0x3ff) == 0) {
				cubs_mark("wake-write", nw);
			}
		}
	}
	__asm__ volatile ("dsb sy; isb" ::: "memory");
	printf("CUBS mba wake replay: msgs %u (responses %u) writes %u skipped %u\n", nmsg, nresp, nw, nskip);
	cubs_mark("wake-replay-done", nw);
	/* cubs_fb_redirect_v22 */
	{
		static const uint32_t cl[] = { 0xf620000u, 0xf618000u, 0xf61c000u, 0xf624000u, 0xf628000u, 0xf62c000u };
		volatile uint32_t *fb = (volatile uint32_t *)ml_io_map(0x9ff400000ULL, 0x400000); /* cubs_fb_v24 */
		volatile uint32_t *sm, *pl;
		uint32_t x, y, cr0, gbpa, a0, a1;
		unsigned k;

		printf("CUBS fb map %p\n", (void *)fb);
		sm = (volatile uint32_t *)cubs_rva(0xf190000ULL);
		if (sm != NULL) {
			cr0 = sm[0x20 / 4];
			gbpa = sm[0x44 / 4];
			printf("CUBS smmu idr0 0x%x cr0 0x%x gbpa 0x%x\n", sm[0], cr0, gbpa);
			cubs_mark("smmu", cr0);
			if (!(cr0 & 1) && (gbpa & (1u << 20))) {
				sm[0x44 / 4] = (gbpa & ~(1u << 20)) | (1u << 31);
				(void)sm[0x44 / 4];
				printf("CUBS smmu gbpa now 0x%x\n", sm[0x44 / 4]);
			}
		}
		if (fb != NULL) {
			for (y = 0; y < 960; y++) {
				for (x = 0; x < 1080; x++) {
					uint32_t c = 0xff000000u;
					if (x < 1080) {
						c |= (y < 808) ? 0xff0000u : ((y < 1616) ? 0x00ff00u : 0x0000ffu);
						if ((x / 90 + y / 90) & 1) {
							c ^= 0x808080u;
						}
					}
					fb[y * 1080 + x] = c;
				}
			}
			__asm__ volatile ("dsb sy; isb" ::: "memory");
			cubs_mark("fb-filled", 0);
		}
		for (k = 0; k < 6; k++) {
			pl = (volatile uint32_t *)cubs_rva((uint64_t)cl[k] + 0x2c);
			if (pl == NULL) {
				continue;
			}
			a0 = pl[0];
			a1 = pl[1];
			printf("CUBS plane %x addr %x %x size %x stride %x\n", cl[k], a0, a1, ((volatile uint32_t *)cubs_rva((uint64_t)cl[k] + 0x5c))[0], ((volatile uint32_t *)cubs_rva((uint64_t)cl[k] + 0x44))[0]);
			pl[0] = 0xff400000u;
			pl[1] = 0x9u;
			((volatile uint32_t *)cubs_rva((uint64_t)cl[k] + 0x44))[0] = 4320;
			((volatile uint32_t *)cubs_rva((uint64_t)cl[k] + 0x88))[0] = (k == 0) ? 0x22009u : 0x22008u; /* cubs_fb_v25 */
		}
		__asm__ volatile ("dsb sy; isb" ::: "memory");
		for (k = 0; k < 6; k++) {
			*(volatile uint32_t *)cubs_rva((uint64_t)cl[k]) = 1;
		}
		*(volatile uint32_t *)cubs_rva(0xf68c000ULL) = 1;
		*(volatile uint32_t *)cubs_rva(0xf680008ULL) = 1;
		__asm__ volatile ("dsb sy; isb" ::: "memory");
		cubs_mark("fb-committed", 0);
		{ unsigned q; /* cubs_rb_v27 */ for (q = 0; q < 3; q++) { delay_for_interval(200000, 1000); cubs_wdt_feed();
		  cubs_mark("rb-p2-00", ((volatile uint32_t *)cubs_rva(0xf620000ULL))[0]);
		  cubs_mark("rb-p2-88", ((volatile uint32_t *)cubs_rva(0xf620088ULL))[0]);
		  cubs_mark("rb-p2-2c", ((volatile uint32_t *)cubs_rva(0xf62002cULL))[0]);
		  cubs_mark("rb-p0-88", ((volatile uint32_t *)cubs_rva(0xf618088ULL))[0]);
		  cubs_mark("rb-g68c000", ((volatile uint32_t *)cubs_rva(0xf68c000ULL))[0]);
		  cubs_mark("rb-g680000", ((volatile uint32_t *)cubs_rva(0xf680000ULL))[0]);
		  cubs_mark("rb-g680004", ((volatile uint32_t *)cubs_rva(0xf680004ULL))[0]);
		  cubs_mark("rb-g680008", ((volatile uint32_t *)cubs_rva(0xf680008ULL))[0]);
		  cubs_mark("irq-fe0-f0", ((volatile uint32_t *)cubs_rva(0xf6000f0ULL))[0]); /* cubs_irq_v32 */
		  cubs_mark("irq-fe1-f0", ((volatile uint32_t *)cubs_rva(0xf6400f0ULL))[0]);
		  cubs_mark("irq-be-1014", ((volatile uint32_t *)cubs_rva(0xf681014ULL))[0]);
		} }
		{ /* cubs_phases_v34: Linux per-frame commit sequence, opaque alpha */
			unsigned ph, yy, xx, kk, fr;
#define CW(a, v) (*(volatile uint32_t *)cubs_rva((uint64_t)(a)) = (v))
			for (ph = 0; ph < 4; ph++) {
				for (yy = 0; yy < 960; yy++) {
					for (xx = 0; xx < 1080; xx++) {
						uint32_t c;
						if (ph == 0) {
							c = 0xffffffffu;
						} else if (ph == 1) {
							c = 0xffff0000u;
						} else if (ph == 2) {
							c = ((yy / 4) & 1) ? 0xffffffffu : 0xff000000u;
						} else {
							c = ((xx / 90 + yy / 90) & 1) ? 0xff00ff00u : 0xff0000ffu;
						}
						fb[yy * 1080 + xx] = c;
					}
				}
				__asm__ volatile ("dsb sy; isb" ::: "memory");
				cubs_mark("phase", ph);
				for (fr = 0; fr < 700; fr++) {
					CW(0xf680008ULL, 2);
					CW(0xf680008ULL, 0x2000000);
					CW(0xf680008ULL, 0x4000000);
					for (kk = 0; kk < 6; kk++) {
						CW(0xf6d7000ULL + 0x1000ULL * kk, 0);
					}
					for (kk = 0; kk < 6; kk++) {
						CW(cl[kk], 1);
					}
					CW(0xf68c000ULL, 1);
					CW(0xf6b606cULL, 1);
					CW(0xf680008ULL, 1);
					CW(0xf6d4004ULL, 0x4320);
					CW(0xf6b6000ULL, 1);
					CW(0xf6b6004ULL, 1);
					CW(0xf680008ULL, 0x2000001);
					CW(0xf680008ULL, 0x4000000);
					CW(0xf6000f0ULL, 0x400);
					CW(0xf6000ecULL, 0xffffff);
					CW(0xf6400ecULL, 0xffffff);
					for (kk = 0; kk < 6; kk++) {
						CW(cl[kk], 0);
					}
					CW(0xf68c000ULL, 0);
					CW(0xf6b606cULL, 0);
					__asm__ volatile ("dsb sy; isb" ::: "memory");
					delay_for_interval(35000, 1000);
					cubs_wdt_feed();
				}
			}
#undef CW
		}
		cubs_mark("fb-hold-done", 0);
	}
}

void
loader_return(void)
{
#if defined(GENERIC_PSCI_SMP)
	/*
	 * With more than one processor: the others switch themselves off first, and the rest of
	 * this is done by the boot processor, the one the loader gave us. This call comes back
	 * on that processor only (on another one it has it call loader_return() in its turn).
	 */
	psci_smp_stop_others();
#endif
	redwood_ufs_quiesce();          /* this kernel's requests to the storage done, UEFI's list as it was, for the log */
	redwood_adreno_quiesce();       /* the GPU block, if it was started, has tables in memory that is about to be reused */
	redwood_wifi_quiesce();         /* the Wi-Fi DSP, if it still runs (a panic), is not left to itself */
	redwood_adsp_quiesce();         /* nor the audio DSP */
	redwood_ddr_quiesce();          /* and the vote for the memory's bandwidth taken away */
	redwood_haptic_quiesce();       /* the vibration motor's chip back into reset, if it was let out */
	redwood_torch_quiesce();        /* the flashlight off, if it was lit */
	redwood_camera_quiesce();       /* the camera powered down, if it was powered up */
	redwood_mic_quiesce();          /* (what the microphones' path did, said again: it happens in the log's middle) */
	/*
	 * A panic's text is first collected in the panic buffer and only later
	 * flushed to the console; if the console itself is what failed, that
	 * never happens. Append the buffer so the loader gets it either way.
	 */
	loader_log_linearize();
	if (!loader_return_entered) {
		loader_log_append_msgbuf();
	}
	if (!loader_return_entered && debug_buf_base != NULL && debug_buf_ptr > debug_buf_base &&
	    (size_t)(debug_buf_ptr - debug_buf_base) < 256 * 1024) {
		loader_log_puts("\n--- panic buffer ---\n");
		for (const char *c = debug_buf_base; c < debug_buf_ptr; c++) {
			loader_log_putc(*c);
		}
	}
	/* CUBS: hand the caller of panic() to the stub as the cookie source */
	{
		/* CUBS: a diagnostic build (checkpoint 250+i) reports the i-th return address up the frame chain */
		uint64_t code = 0, n = loader_stub_slot[2];
		uint64_t *fp = (uint64_t *)__builtin_frame_address(0);
		uint64_t ra[12];
		unsigned cnt = 0;
		while (cnt < 12 && fp != NULL && ((uintptr_t)fp & 7) == 0 && (uintptr_t)fp > 0xfffffff000000000ULL) {
			ra[cnt++] = fp[1];
			uint64_t *next = (uint64_t *)fp[0];
			if (next <= fp) {
				break;
			}
			fp = next;
		}
		if (n == 250) {
			code = (uint64_t)cubs_assert_line;
		} else if (n == 251) {
			code = (uint64_t)(uintptr_t)cubs_assert_file;
		} else if (n == 252) {
			code = (uint64_t)(uintptr_t)cubs_assert_expr;
		} else if (n == 253) {
			code = cubs_exc_far;
		} else if (n == 254) {
			code = (uint64_t)(uintptr_t)cubs_exc_msg;
		} else if (n == 257) {
			code = cubs_init_exit;
		} else if (n == 258) {
			code = cubs_gic_sample;
		} else if (n == 259) {
			code = cubs_daif_bits;
		} else if (n == 255) {
			code = (uint64_t)(uintptr_t)debugger_panic_str;
		} else if (n == 499) {
			/* CUBS: full boot: process 1's exit status if it ran and exited, else the panic string address */
			code = cubs_init_exit ? cubs_init_exit : (debugger_panic_str != NULL ? (uint64_t)(uintptr_t)debugger_panic_str : 0x20000000ULL | (((cnt > 0 ? ra[0] : 0) - 0xfffffff007004000ULL) >> 2 & 0x3fffffULL));
		}
		cubs_dump_log_to_ufs();
		loader_jump(0, code);
	}
}

/* Bring-up aid: stop here if the loader asked for checkpoint n. */
void
loader_checkpoint(uint64_t n)
{
	if (loader_stub_slot[2] == n) {
		__asm__ volatile ("msr DAIFSet, #0xf" ::: "memory"); /* CUBS: no interrupt may land between the match and the reset call */
		/*
		 * This early C checkpoint runs before a platform console exists. The
		 * normal loader return path only supports 4 KiB XNU pages; stop with
		 * PSCI directly so the 16 KiB HackiOS kernel has an unambiguous marker.
		 */
		/*
		 * CUBS bring-up: first ask for PSCI SYSTEM_RESET2 with a vendor reset type and a
		 * cookie, so the bootloader can report this stop as something other than a crash.
		 * If the firmware refuses, fall back to plain SYSTEM_RESET. Either way the phone
		 * restarts by itself.
		 */
		register uint64_t reset2_fn __asm__("x0") = 0x84000012ULL;
		register uint64_t reset_type __asm__("x1") = 0x80000001ULL;
		register uint64_t reset_cookie __asm__("x2") = 0xcb05c0deULL;
		__asm__ volatile ("smc #0" : "+r" (reset2_fn), "+r" (reset_type), "+r" (reset_cookie) : : "x3", "memory");
		register uint64_t function_id __asm__("x0") = 0x84000009ULL; /* PSCI SYSTEM_RESET (fallback) */
		__asm__ volatile ("smc #0" : "+r" (function_id) : : "x1", "x2", "x3", "memory");
		for (;;) {
			__asm__ volatile ("wfe" ::: "memory");
		}
	}
}

/*
 * boot-arg loader_return_after=<seconds>: hand control back to the loader
 * after that long, whatever the kernel is doing. This is how the log gets out
 * when the kernel does not panic but simply waits (e.g. for a root device).
 */
/*
 * For trying the ways out when there is more than one processor: boot-arg return_cpu=<n> has
 * that processor make the timed return, from an interrupt handler -- any but the boot processor
 * has to hand it over (psci_smp_stop_others()) --, and return_panic=1 makes a panic of it.
 */
static void
loader_return_test(void *as_panic)
{
	if (as_panic != (void *)1) {
		panic("return_panic: the panic that was asked for, on cpu %d", cpu_number());
	}
	loader_return();
}

static void
loader_return_timer(__unused thread_call_param_t p0, __unused thread_call_param_t p1)
{
	static const char banner[] = "\n--- loader_return_after expired ---\n";
	uint32_t cpu = 0, as_panic = 0;

	for (const char *c = banner; *c; c++) {
		loader_log_putc(*c);
	}
	PE_parse_boot_argn("return_panic", &as_panic, sizeof(as_panic));
	if (!as_panic) {
		redwood_var_save_on_return();   /* the data volume kept, while the system is still whole */
		redwood_adreno_stop();          /* a GPU kept for the system is given back while there is a thread to wait in */
		redwood_wifi_stop();            /* and the Wi-Fi DSP, if it runs, shut down */
		redwood_adsp_stop();            /* and the audio DSP */
	}
	if (PE_parse_boot_argn("return_cpu", &cpu, sizeof(cpu)) && cpu <= (uint32_t)ml_get_max_cpu_number() &&
	    cpu_xcall((int)cpu, loader_return_test, (void *)(uintptr_t)(as_panic ? 2 : 1)) == KERN_SUCCESS) {
		for (;;) {
			delay_for_interval(1000, NSEC_PER_MSEC);        /* that processor ends it */
		}
	}
	loader_return_test((void *)(uintptr_t)(as_panic ? 2 : 1));
}

__startup_func
static void
loader_return_timer_init(void)
{
	uint32_t seconds = 0;
	uint64_t deadline;

	if (!PE_parse_boot_argn("loader_return_after", &seconds, sizeof(seconds)) || seconds == 0) {
		return;
	}
	thread_call_t call = thread_call_allocate(loader_return_timer, NULL);
	clock_interval_to_deadline(seconds, NSEC_PER_SEC, &deadline);
	thread_call_enter_delayed(call, deadline);
}
STARTUP(EARLY_BOOT, STARTUP_RANK_LAST, loader_return_timer_init);

/*
 * A loader that watches from another core also listens to the host, and passes on a request to
 * end the run ("xl stop") by setting loader_live.stop. Look once a second.
 */
static thread_call_t loader_stop_call;

static void
loader_stop_poll(__unused thread_call_param_t p0, __unused thread_call_param_t p1)
{
	uint64_t deadline;

	if (loader_live.stop) {
		static const char banner[] = "\n--- the host asked for the end of the run: back to the loader ---\n";
		for (const char *c = banner; *c; c++) {
			loader_log_putc(*c);
		}
		redwood_var_save_on_return();
		redwood_adreno_stop();
		redwood_wifi_stop();
		redwood_adsp_stop();
		loader_return();
	}
	clock_interval_to_deadline(1, NSEC_PER_SEC, &deadline);
	thread_call_enter_delayed(loader_stop_call, deadline);
}

__startup_func
static void
loader_stop_poll_init(void)
{
	loader_stop_call = thread_call_allocate(loader_stop_poll, NULL);
	loader_stop_poll(NULL, NULL);
}
STARTUP(EARLY_BOOT, STARTUP_RANK_LAST, loader_stop_poll_init);

/*
 * boot-arg hv_wdt_pet=1: the loader has armed the Qualcomm hypervisor's
 * virtual watchdog (it resets the phone when a kernel hangs, so that test
 * runs need nobody at the device). Its timeout is at most 65 seconds; feed
 * it from a timer so that a healthy kernel can run for as long as it likes.
 */
#define VIRT_WDT_PET            0x86000007u
#define HV_WDT_PET_SECONDS      10

static thread_call_t hv_wdt_call;
static uint32_t hv_wdt_enabled;

#define MEMORY_REPORT_BEATS     6               /* a line about memory every so many heartbeats */

extern unsigned int memorystatus_available_pages, memorystatus_available_pages_critical,
    memorystatus_available_pages_critical_base;
extern uint32_t c_segment_pages_compressed;
extern _Atomic uint64_t ramfs_pages_in_use;
extern void MiniIOSurfaceUsage(uint32_t *count, uint64_t *bytes);

/*
 * Where the memory is, in megabytes: for reading a session's log afterwards. "available" is what
 * the kernel's own count says (free and file-backed): below the first threshold it kills idle
 * daemons, and once none is left and it is below the second, whatever is next in line -- the
 * window server included.
 */
void redwood_memory_line(char *buf, size_t len);

/* The line itself (also kern.redwood_memory, for a job list to keep: bsd/miscfs/apfs/apfs_vfsops.c) */
void
redwood_memory_line(char *buf, size_t len)
{
#define MB(pages)       ((unsigned int)(((uint64_t)(pages) * PAGE_SIZE) >> 20))
	uint32_t surfaces = 0;
	uint64_t surface_bytes = 0;

	MiniIOSurfaceUsage(&surfaces, &surface_bytes);
	snprintf(buf, len, "memory: free %u, files %u, programs %u, wired %u (%u surfaces %u, ramfs %u), compressor %u "
	    "(holding %u) MB; available %u, kills below %u (the idle) and %u (anybody)\n",
	    MB(vm_page_free_count), MB(vm_page_pageable_external_count), MB(vm_page_pageable_internal_count),
	    MB(vm_page_wire_count), surfaces, (unsigned int)(surface_bytes >> 20),
	    MB(os_atomic_load(&ramfs_pages_in_use, relaxed)),
	    MB(VM_PAGE_COMPRESSOR_COUNT), MB(c_segment_pages_compressed),
	    MB(memorystatus_available_pages),
	    MB(memorystatus_available_pages_critical), MB(memorystatus_available_pages_critical_base));
#undef MB
}

static void
memory_report(void)
{
	char line[256];

	redwood_memory_line(line, sizeof(line));
	printf("%s", line);
	redwood_adreno_minute();                /* (and how warm the GPU is, if it is in use) */
}

/* Every HV_WDT_PET_SECONDS: feed the watchdog if there is one, and show any watching loader a sign of life. */
static void
hv_wdt_pet(__unused thread_call_param_t p0, __unused thread_call_param_t p1)
{
	uint64_t deadline;

	if (hv_wdt_enabled) {
		register uint64_t x0 __asm__("x0") = VIRT_WDT_PET;
		register uint64_t x1 __asm__("x1") = 0;
		register uint64_t x2 __asm__("x2") = 0;
		register uint64_t x3 __asm__("x3") = 0;

		__asm__ volatile ("smc #0" : "+r" (x0), "+r" (x1), "+r" (x2), "+r" (x3) : :
		    "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17");
	}
	if (++loader_live.heartbeat % MEMORY_REPORT_BEATS == 0) {
		memory_report();
	}

	clock_interval_to_deadline(HV_WDT_PET_SECONDS, NSEC_PER_SEC, &deadline);
	thread_call_enter_delayed(hv_wdt_call, deadline);
}

__startup_func
static void
hv_wdt_pet_init(void)
{
	PE_parse_boot_argn("hv_wdt_pet", &hv_wdt_enabled, sizeof(hv_wdt_enabled));
	hv_wdt_call = thread_call_allocate(hv_wdt_pet, NULL);
	hv_wdt_pet(NULL, NULL);
}
STARTUP(EARLY_BOOT, STARTUP_RANK_LAST, hv_wdt_pet_init);
extern unsigned int processor_avail_count;

#include <vm/vm_kern.h>
#include <arm/caches_internal.h>

/*
 * CUBS display (boot-arg cubs_blit=1|2): the panel is still lit and scanned by the DPU with the page list of a linear
 * framebuffer that Linux's DRM driver set up before the hand-over (tools drmfb). The list sits in the spare tail of the
 * framebuffer carve (video base + 0xA00000): header {magic, nruns, w, h, pitch, bpp, size, 0}, then {pa, len} runs.
 * cubs_blit=1 copies the RAM framebuffer (boot_args.Video) into those pages ten times a second;
 * cubs_blit=2 draws a colour-cycling test pattern into them instead (proves the path without iOS drawing anything).
 */
#define CUBS_BLIT_MAGIC 0x3130424643425543ULL
#define CUBS_BLIT_MAXRUNS 2688     /* a 10.5 MB buffer is at most 2576 pages, and the list page holds 4092 runs */
struct cubs_blit_hdr { uint64_t magic, nruns, w, h, pitch, bpp, size, rsv; };
struct cubs_blit_run { uint64_t pa, len; };
static struct { volatile uint8_t *va; uint64_t start, len; } cubs_blit_run_map[CUBS_BLIT_MAXRUNS];
static uint32_t cubs_blit_nruns, cubs_blit_mode, cubs_blit_ready, cubs_blit_dead;
static uint64_t cubs_blit_pitch, cubs_blit_w, cubs_blit_h, cubs_blit_frames, cubs_blit_nz;
static volatile uint8_t *cubs_blit_src, *cubs_blit_dpu;
static uint32_t cubs_blit_commit;
static thread_call_t cubs_blit_call;
/* fast path (boot-arg cubs_blit_fast, default 1): cacheable source + shadow compare, only changed 16-row bands are
 * written to the scan-out pages and the DPU commit runs only when something changed */
static uint32_t cubs_blit_fast = 1, cubs_blit_ms, cubs_blit_dirty;
static volatile uint8_t *cubs_blit_srcc;
static uint8_t *cubs_blit_shadow;
static uint64_t cubs_blit_cost_us, cubs_blit_cost_n;
/* tear avoidance (boot-arg cubs_blit_hold, ms, default 20, 0 = off): the DPU reads the scan-out pages for a while after each commit, so the next band writes
 * wait until that read-out has had time to finish; writes then never overlap a frame in flight */
static uint32_t cubs_blit_hold = 20;
static uint64_t cubs_blit_last_commit, cubs_blit_holds;
#define CUBS_BLIT_BAND 16

static void
cubs_blit_setup(void)
{
	uint64_t lpa = PE_state.video.v_baseAddr + 0xA00000ULL, off = 0;
	volatile struct cubs_blit_hdr *h = (volatile struct cubs_blit_hdr *)ml_io_map_wcomb(lpa, 0x10000);
	volatile struct cubs_blit_run *r;
	uint32_t i;

	if (h == NULL || h->magic != CUBS_BLIT_MAGIC || h->nruns == 0 || h->nruns > CUBS_BLIT_MAXRUNS || h->bpp != 32) {
		printf("CUBS blit: no valid page list at %llx (magic %llx runs %llu)\n", lpa, h ? h->magic : 0, h ? h->nruns : 0);
		cubs_blit_dead = 1;
		return;
	}
	r = (volatile struct cubs_blit_run *)((volatile uint8_t *)h + sizeof(*h));
	cubs_blit_nruns = (uint32_t)h->nruns;
	cubs_blit_w = h->w; cubs_blit_h = h->h; cubs_blit_pitch = h->pitch;
	for (i = 0; i < cubs_blit_nruns; i++) {
		cubs_blit_run_map[i].va = (volatile uint8_t *)ml_io_map_wcomb(r[i].pa, r[i].len);
		cubs_blit_run_map[i].start = off;
		cubs_blit_run_map[i].len = r[i].len;
		off += r[i].len;
		if (cubs_blit_run_map[i].va == NULL) {
			printf("CUBS blit: map of run %u failed\n", i);
			cubs_blit_dead = 1;
			return;
		}
	}
	if (cubs_blit_mode == 1) {
		uint64_t fbsize = (uint64_t)PE_state.video.v_rowBytes * PE_state.video.v_height;

		cubs_blit_src = (volatile uint8_t *)ml_io_map_wcomb(PE_state.video.v_baseAddr, fbsize);
		if (cubs_blit_src == NULL) {
			printf("CUBS blit: source map failed\n");
			cubs_blit_dead = 1;
			return;
		}
		if (cubs_blit_fast) {
			vm_offset_t sh = 0;

			cubs_blit_srcc = (volatile uint8_t *)io_map(PE_state.video.v_baseAddr, fbsize, VM_WIMG_DEFAULT, VM_PROT_DEFAULT, false);
			kmem_alloc(kernel_map, &sh, round_page(fbsize), KMA_NOFAIL | KMA_ZERO | KMA_DATA, VM_KERN_MEMORY_DIAG);
			cubs_blit_shadow = (uint8_t *)sh;
			if (cubs_blit_srcc == NULL || cubs_blit_shadow == NULL) {
				printf("CUBS blit: fast path unavailable, using the plain copy\n");
				cubs_blit_fast = 0;
			}
		}
	}
	if (cubs_blit_commit) {
		cubs_blit_dpu = (volatile uint8_t *)ml_io_map(0xf600000ULL, 0x120000);
		if (cubs_blit_dpu == NULL) {
			cubs_blit_dead = 1;
			return;
		}
		printf("CUBS blit: dpu 0x%x\n", ((volatile uint32_t *)cubs_blit_dpu)[0x80004 / 4]);
	}
	printf("CUBS blit: %u runs, %llux%llu pitch %llu, mode %u ready\n", cubs_blit_nruns, cubs_blit_w, cubs_blit_h,
	    cubs_blit_pitch, cubs_blit_mode);
	cubs_blit_ready = 1;
}

/* copy n bytes (multiples of 8) to offset doff of the scan-out buffer; *cur is the run to start looking from */
static void
cubs_blit_put(uint32_t *cur, uint64_t doff, const volatile uint64_t *s, uint64_t n)
{
	while (n && *cur < cubs_blit_nruns) {
		uint64_t st = cubs_blit_run_map[*cur].start, ln = cubs_blit_run_map[*cur].len;
		if (doff >= st + ln) {
			(*cur)++;
			continue;
		}
		uint64_t c = st + ln - doff;
		if (c > n) {
			c = n;
		}
		volatile uint64_t *d = (volatile uint64_t *)(cubs_blit_run_map[*cur].va + (doff - st));
		for (uint64_t i = 0; i < c / 8; i++) {
			d[i] = s[i];
		}
		doff += c; n -= c; s += c / 8;
	}
}

static void
cubs_blit_fill(uint32_t color)
{
	for (uint32_t i = 0; i < cubs_blit_nruns; i++) {
		volatile uint64_t *d = (volatile uint64_t *)cubs_blit_run_map[i].va;
		uint64_t v = ((uint64_t)color << 32) | color;
		for (uint64_t k = 0; k < cubs_blit_run_map[i].len / 8; k++) {
			d[k] = v;
		}
	}
}

/*
 * Event-driven blitting: MiniIOMobileFramebuffer::show() calls cubs_blit_frame_done() when a swap has been composited
 * into the boot framebuffer. The blit then runs a couple of milliseconds later; between frames nothing is polled except
 * a slow safety pass (a frame drawn by the kernel console, before iOS draws, does not announce itself).
 */
static volatile uint32_t cubs_blit_pending, cubs_blit_events;
static volatile uint32_t cubs_gpu_dirty;        /* the GPU client pasted pixels: the DPU commit must run (cubs_gpu.c.inc) */

void
cubs_blit_frame_done(void)
{
	uint64_t deadline;

	cubs_blit_events++;
	cubs_blit_pending = 1;
	if (cubs_blit_call != NULL && cubs_blit_ready) {
		clock_interval_to_deadline(2, NSEC_PER_MSEC, &deadline);
		thread_call_enter_delayed(cubs_blit_call, deadline);
	}
}

/* boot-arg cubs_shot=1: every ~5 s a quarter-size copy of the iOS framebuffer goes into the shared RAM (PA 0xab2000000 + 0x1C00000: "SHOT", sequence, width, height, then BGRA) for the host to read */
static uint32_t cubs_shot_on, cubs_shot_seq;
static volatile uint8_t *cubs_shot_ring;

static void
cubs_shot_take(void)
{
	uint32_t W, H, y, x;
	uint64_t pitch = PE_state.video.v_rowBytes;
	volatile uint32_t *dst;

	if (cubs_blit_srcc == NULL) {
		return;
	}
	if (cubs_shot_ring == NULL) {
		cubs_shot_ring = (volatile uint8_t *)io_map(0xab2000000ULL + 0x1C00000ULL, 0x400000, VM_WIMG_DEFAULT, VM_PROT_DEFAULT, false);
		if (cubs_shot_ring == NULL) {
			return;
		}
	}
	W = 540;
	H = 1212;
	dst = (volatile uint32_t *)(cubs_shot_ring + 0x1000);
	for (y = 0; y < H; y++) {
		const volatile uint32_t *row = (const volatile uint32_t *)(cubs_blit_srcc + (uint64_t)(2 * y) * pitch);

		for (x = 0; x < W; x++) {
			dst[y * W + x] = row[2 * x];
		}
	}
	((volatile uint32_t *)cubs_shot_ring)[1] = ++cubs_shot_seq;
	((volatile uint32_t *)cubs_shot_ring)[2] = W;
	((volatile uint32_t *)cubs_shot_ring)[3] = H;
	__asm__ volatile ("dsb sy" ::: "memory");
	((volatile uint32_t *)cubs_shot_ring)[0] = 0x544f4853;
	FlushPoC_DcacheRegion((vm_offset_t)cubs_shot_ring, 0x1000 + W * H * 4);
	printf("CUBS shot: %u taken\n", cubs_shot_seq);
}

static void
cubs_blit_tick(__unused thread_call_param_t p0, __unused thread_call_param_t p1)
{
	static const uint32_t col[4] = { 0xff0000, 0x00ff00, 0x0000ff, 0xffffff };
	uint64_t deadline;

	if (cubs_blit_dead) {
		return;
	}
	if (!cubs_blit_ready) {
		cubs_blit_setup();
		if (cubs_blit_dead) {
			return;
		}
	}
	if (cubs_blit_mode == 1 && cubs_blit_fast && cubs_blit_events != 0 && !cubs_blit_pending) {
		static uint32_t idle;

		if ((++idle & 3) != 0) {        /* safety pass only every 4th slow tick */
			clock_interval_to_deadline(500, NSEC_PER_MSEC, &deadline);
			thread_call_enter_delayed(cubs_blit_call, deadline);
			return;
		}
	}
	if (cubs_blit_commit && cubs_blit_hold && cubs_blit_last_commit) {
		uint64_t ns, hold_ns = (uint64_t)cubs_blit_hold * NSEC_PER_MSEC;

		absolutetime_to_nanoseconds(mach_absolute_time() - cubs_blit_last_commit, &ns);
		if (ns < hold_ns) {
			cubs_blit_holds++;
			clock_interval_to_deadline((hold_ns - ns) / 1000 + 1, NSEC_PER_USEC, &deadline);
			thread_call_enter_delayed(cubs_blit_call, deadline);
			return;
		}
	}
	cubs_blit_pending = 0;
	uint64_t t0 = mach_absolute_time();

	cubs_blit_dirty = 1;
	if (cubs_blit_mode == 2) {
		cubs_blit_fill(col[(cubs_blit_frames / 20) & 3]);
	} else if (cubs_blit_fast) {
		uint32_t cur = 0;
		uint64_t rb = PE_state.video.v_rowBytes;

		cubs_blit_dirty = 0;
		cubs_blit_nz = 0;
		FlushPoC_DcacheRegion((vm_offset_t)cubs_blit_srcc, rb * cubs_blit_h);
		for (uint64_t y0 = 0; y0 < cubs_blit_h; y0 += CUBS_BLIT_BAND) {
			uint64_t rows = cubs_blit_h - y0 < CUBS_BLIT_BAND ? cubs_blit_h - y0 : CUBS_BLIT_BAND;

			if (memcmp((const void *)(cubs_blit_srcc + y0 * rb), cubs_blit_shadow + y0 * rb, rows * rb) != 0) {
				memcpy(cubs_blit_shadow + y0 * rb, (const void *)(cubs_blit_srcc + y0 * rb), rows * rb);
				for (uint64_t y = y0; y < y0 + rows; y++) {
					cubs_blit_put(&cur, y * cubs_blit_pitch, (const volatile uint64_t *)(cubs_blit_shadow + y * rb), rb);
				}
				cubs_blit_dirty = 1;
				cubs_blit_nz++;     /* bands written */
			}
		}
	} else {
		uint32_t cur = 0;
		uint64_t rb = PE_state.video.v_rowBytes;
		cubs_blit_nz = 0;
		for (uint64_t y = 0; y < cubs_blit_h; y++) {
			const volatile uint64_t *row = (const volatile uint64_t *)(cubs_blit_src + y * rb);
			if ((y & 7) == 0) {
				for (uint64_t k = 0; k < rb / 8; k++) {
					if (row[k] != *(const volatile uint64_t *)cubs_blit_src) {
						cubs_blit_nz++;
					}
				}
			}
			cubs_blit_put(&cur, y * cubs_blit_pitch, row, rb);
		}
	}
	__asm__ volatile ("dsb sy" ::: "memory");
	if (cubs_gpu_dirty) {
		cubs_gpu_dirty = 0;
		cubs_blit_dirty = 1;
	}
	if (cubs_blit_commit && cubs_blit_dirty) {
		/* Linux's per-frame DPU commit sequence (captured in the wake trace), planes at 0xf618000 + 0x4000 * k */
#define CBW(a, v) (*(volatile uint32_t *)(cubs_blit_dpu + ((uint64_t)(a) - 0xf600000ULL)) = (v))
		CBW(0xf680008ULL, 2);
		CBW(0xf680008ULL, 0x2000000);
		CBW(0xf680008ULL, 0x4000000);
		for (uint32_t kk = 0; kk < 6; kk++) {
			CBW(0xf6d7000ULL + 0x1000ULL * kk, 0);
		}
		for (uint32_t kk = 0; kk < 6; kk++) {
			CBW(0xf618000ULL + 0x4000ULL * kk, 1);
		}
		CBW(0xf68c000ULL, 1);
		CBW(0xf6b606cULL, 1);
		CBW(0xf680008ULL, 1);
		CBW(0xf6d4004ULL, 0x4320);
		CBW(0xf6b6000ULL, 1);
		CBW(0xf6b6004ULL, 1);
		CBW(0xf680008ULL, 0x2000001);
		CBW(0xf680008ULL, 0x4000000);
		CBW(0xf6000f0ULL, 0x400);
		CBW(0xf6000ecULL, 0xffffff);
		CBW(0xf6400ecULL, 0xffffff);
		for (uint32_t kk = 0; kk < 6; kk++) {
			CBW(0xf618000ULL + 0x4000ULL * kk, 0);
		}
		CBW(0xf68c000ULL, 0);
		CBW(0xf6b606cULL, 0);
#undef CBW
		__asm__ volatile ("dsb sy; isb" ::: "memory");
		cubs_blit_last_commit = mach_absolute_time();
	}
	{
		uint64_t ns;

		absolutetime_to_nanoseconds(mach_absolute_time() - t0, &ns);
		cubs_blit_cost_us += ns / 1000;
		cubs_blit_cost_n++;
	}
	if ((++cubs_blit_frames % 50) == 1) {
		printf("CUBS blit: frame %llu\n", cubs_blit_frames);
		printf("CUBS blit: holds 0x%llx\n", cubs_blit_holds);
		if (cubs_shot_on) {
			cubs_shot_take();
		}
		printf("CUBS blit: processors %u, this one %d\n", (unsigned)processor_avail_count, (int)cpu_number());
		printf("CUBS blit: fb pa %#llx rowbytes %lu height %lu\n", (unsigned long long)PE_state.video.v_baseAddr, (unsigned long)PE_state.video.v_rowBytes, (unsigned long)PE_state.video.v_height);
		printf("CUBS blit: nz 0x%llx\n", cubs_blit_nz);
		printf("CUBS blit: cost 0x%llx\n", cubs_blit_cost_us / (cubs_blit_cost_n ? cubs_blit_cost_n : 1));
		{
			/* probe: non-zero words (every 64th) seen through the cacheable alias, the write-combined alias and the shadow */
			uint64_t fbs = (uint64_t)PE_state.video.v_rowBytes * PE_state.video.v_height, o;
			uint32_t pa = 0, pb = 0, pc = 0;

			for (o = 0; o + 4 <= fbs; o += 256) {
				if (cubs_blit_srcc && *(volatile uint32_t *)(cubs_blit_srcc + o)) {
					pa++;
				}
				if (cubs_blit_src && *(volatile uint32_t *)(cubs_blit_src + o)) {
					pb++;
				}
				if (cubs_blit_shadow && *(uint32_t *)(cubs_blit_shadow + o)) {
					pc++;
				}
			}
			printf("CUBS blit: probe cacheable %u wcomb %u shadow %u fast %u\n", pa, pb, pc, cubs_blit_fast);
			if (cubs_blit_shadow) {
				/* pixels that are really drawn (not 0 / opaque black) in the shadow: are they in the scan-out pages too? */
				uint32_t lit = 0, miss = 0, litsrc = 0;
				uint64_t rb2 = PE_state.video.v_rowBytes, y2, x2;

				for (y2 = 0; y2 < PE_state.video.v_height; y2 += 8) {
					for (x2 = 0; x2 < 1080; x2 += 8) {
						uint32_t sh = *(uint32_t *)(cubs_blit_shadow + y2 * rb2 + x2 * 4);
						uint32_t so = 0xdeadbeef;

						if (cubs_blit_srcc && (*(volatile uint32_t *)(cubs_blit_srcc + y2 * rb2 + x2 * 4) & 0xffffff)) {
							litsrc++;
						}
						if ((sh & 0xffffff) == 0) {
							continue;
						}
						lit++;
						for (uint32_t r = 0; r < cubs_blit_nruns; r++) {
							uint64_t doff = y2 * cubs_blit_pitch + x2 * 4, st = cubs_blit_run_map[r].start;

							if (doff >= st && doff < st + cubs_blit_run_map[r].len) {
								so = *(volatile uint32_t *)(cubs_blit_run_map[r].va + (doff - st));
								break;
							}
						}
						if (so != sh) {
							miss++;
						}
					}
				}
				printf("CUBS blit: lit src %u shadow %u scanout-miss %u\n", litsrc, lit, miss);
			}
		}
		cubs_blit_cost_us = 0;
		cubs_blit_cost_n = 0;
	}
	clock_interval_to_deadline(cubs_blit_pending ? 2 : (cubs_blit_events != 0 && cubs_blit_mode == 1 && cubs_blit_fast ? 500 : cubs_blit_ms), NSEC_PER_MSEC, &deadline);
	thread_call_enter_delayed(cubs_blit_call, deadline);
}

__startup_func
static void
cubs_blit_init(void)
{
	uint64_t deadline;

	if (!PE_parse_boot_argn("cubs_blit", &cubs_blit_mode, sizeof(cubs_blit_mode)) || cubs_blit_mode == 0) {
		return;
	}
	if (cubs_blit_mode >= 3) {      /* 3 = iOS framebuffer + per-frame DPU commit, 4 = colour cycle + commit */
		cubs_blit_commit = 1;
		cubs_blit_mode = cubs_blit_mode == 4 ? 2 : 1;
	}
	(void)PE_parse_boot_argn("cubs_blit_fast", &cubs_blit_fast, sizeof(cubs_blit_fast));
	(void)PE_parse_boot_argn("cubs_blit_hold", &cubs_blit_hold, sizeof(cubs_blit_hold));
	(void)PE_parse_boot_argn("cubs_shot", &cubs_shot_on, sizeof(cubs_shot_on));
	if (!PE_parse_boot_argn("cubs_blit_ms", &cubs_blit_ms, sizeof(cubs_blit_ms)) || cubs_blit_ms == 0) {
		cubs_blit_ms = 100;
	}
	cubs_blit_call = thread_call_allocate(cubs_blit_tick, NULL);
	clock_interval_to_deadline(5, NSEC_PER_SEC, &deadline);
	thread_call_enter_delayed(cubs_blit_call, deadline);
}
STARTUP(EARLY_BOOT, STARTUP_RANK_LAST, cubs_blit_init);
static const uint32_t cubs_gpu_tab[64 * 18] = {
0x00000000,0xbe88df0d,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f19999a,0x3e88df0d,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf19999a,0x3e88df0d,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3d70e30d,0xbe883654,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f09ce11,0x3e95a0c1,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf27ea72,0x3e7597cd,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3defba1c,0xbe863dc9,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3ef15d91,0x3ea0f190,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf349d4f,0x3e571402,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3e3259d5,0xbe82fa48,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3ecccbef,0x3eaab594,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf3f92e2,0x3e367df6,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3e6b1ee6,0xbe7ce7b9,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3ea64165,0x3eb2d4b9,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf48b025,0x3e1425fe,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3e90d026,0xbe716b5e,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3e7c39ed,0x3eb93afa,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf4fdea1,0x3de0c18f,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3eaaabd2,0xbe639bcf,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3e298338,0x3ebdd88f,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf550ca0,0x3d970d02,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3ec2e2b8,0xbe539b1a,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3daa5531,0x3ec0a217,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf582d5e,0x3d17c81c,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3ed93924,0xbe4190b3,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x00000000,0x3ec190b3,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf593924,0x00000000,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3eed7804,0xbe2da913,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbdaa5531,0x3ec0a217,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf582d5e,0xbd17c81c,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3eff6d6e,0xbe18154e,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbe298338,0x3ebdd88f,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf550ca0,0xbd970d02,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3f07768e,0xbe010a96,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbe7c39ed,0x3eb93afa,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf4fdea1,0xbde0c18f,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3f0de86c,0xbdd18374,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbea64165,0x3eb2d4b9,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf48b025,0xbe1425fe,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3f12fc6d,0xbd9eed32,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbecccbef,0x3eaab594,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf3f92e2,0xbe367df6,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3f16a60c,0xbd559e3c,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbef15d91,0x3ea0f190,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf349d4f,0xbe571402,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3f18dc41,0xbcd6a6d7,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf09ce11,0x3e95a0c1,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf27ea72,0xbe7597cd,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3f19999a,0xa396fa4e,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf19999a,0x3e88df0d,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf19999a,0xbe88df0d,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3f18dc41,0x3cd6a6d7,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf27ea72,0x3e7597cd,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf09ce11,0xbe95a0c1,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3f16a60c,0x3d559e3c,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf349d4f,0x3e571402,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbef15d91,0xbea0f190,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3f12fc6d,0x3d9eed32,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf3f92e2,0x3e367df6,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbecccbef,0xbeaab594,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3f0de86c,0x3dd18374,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf48b025,0x3e1425fe,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbea64165,0xbeb2d4b9,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3f07768e,0x3e010a96,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf4fdea1,0x3de0c18f,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbe7c39ed,0xbeb93afa,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3eff6d6e,0x3e18154e,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf550ca0,0x3d970d02,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbe298338,0xbebdd88f,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3eed7804,0x3e2da913,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf582d5e,0x3d17c81c,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbdaa5531,0xbec0a217,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3ed93924,0x3e4190b3,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf593924,0x23e41e6a,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xa4800000,0xbec190b3,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3ec2e2b8,0x3e539b1a,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf582d5e,0xbd17c81c,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3daa5531,0xbec0a217,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3eaaabd2,0x3e639bcf,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf550ca0,0xbd970d02,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3e298338,0xbebdd88f,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3e90d026,0x3e716b5e,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf4fdea1,0xbde0c18f,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3e7c39ed,0xbeb93afa,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3e6b1ee6,0x3e7ce7b9,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf48b025,0xbe1425fe,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3ea64165,0xbeb2d4b9,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3e3259d5,0x3e82fa48,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf3f92e2,0xbe367df6,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3ecccbef,0xbeaab594,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3defba1c,0x3e863dc9,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf349d4f,0xbe571402,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3ef15d91,0xbea0f190,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x3d70e30d,0x3e883654,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf27ea72,0xbe7597cd,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f09ce11,0xbe95a0c1,0x00000000,0x00000000,0x3f800000,0x3f800000,
0x24a96e3c,0x3e88df0d,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf19999a,0xbe88df0d,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f19999a,0xbe88df0d,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbd70e30d,0x3e883654,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbf09ce11,0xbe95a0c1,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f27ea72,0xbe7597cd,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbdefba1c,0x3e863dc9,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbef15d91,0xbea0f190,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f349d4f,0xbe571402,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbe3259d5,0x3e82fa48,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbecccbef,0xbeaab594,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f3f92e2,0xbe367df6,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbe6b1ee6,0x3e7ce7b9,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbea64165,0xbeb2d4b9,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f48b025,0xbe1425fe,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbe90d026,0x3e716b5e,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbe7c39ed,0xbeb93afa,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f4fdea1,0xbde0c18f,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbeaaabd2,0x3e639bcf,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbe298338,0xbebdd88f,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f550ca0,0xbd970d02,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbec2e2b8,0x3e539b1a,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xbdaa5531,0xbec0a217,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f582d5e,0xbd17c81c,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbed93924,0x3e4190b3,0x3f800000,0x00000000,0x00000000,0x3f800000,
0xa5400000,0xbec190b3,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f593924,0xa4ab16d0,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbeed7804,0x3e2da913,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3daa5531,0xbec0a217,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f582d5e,0x3d17c81c,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbeff6d6e,0x3e18154e,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3e298338,0xbebdd88f,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f550ca0,0x3d970d02,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbf07768e,0x3e010a96,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3e7c39ed,0xbeb93afa,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f4fdea1,0x3de0c18f,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbf0de86c,0x3dd18374,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3ea64165,0xbeb2d4b9,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f48b025,0x3e1425fe,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbf12fc6d,0x3d9eed32,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3ecccbef,0xbeaab594,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f3f92e2,0x3e367df6,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbf16a60c,0x3d559e3c,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3ef15d91,0xbea0f190,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f349d4f,0x3e571402,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbf18dc41,0x3cd6a6d7,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f09ce11,0xbe95a0c1,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f27ea72,0x3e7597cd,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbf19999a,0x24627776,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f19999a,0xbe88df0d,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f19999a,0x3e88df0d,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbf18dc41,0xbcd6a6d7,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f27ea72,0xbe7597cd,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3f09ce11,0x3e95a0c1,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbf16a60c,0xbd559e3c,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f349d4f,0xbe571402,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3ef15d91,0x3ea0f190,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbf12fc6d,0xbd9eed32,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f3f92e2,0xbe367df6,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3ecccbef,0x3eaab594,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbf0de86c,0xbdd18374,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f48b025,0xbe1425fe,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3ea64165,0x3eb2d4b9,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbf07768e,0xbe010a96,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f4fdea1,0xbde0c18f,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3e7c39ed,0x3eb93afa,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbeff6d6e,0xbe18154e,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f550ca0,0xbd970d02,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3e298338,0x3ebdd88f,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbeed7804,0xbe2da913,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f582d5e,0xbd17c81c,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x3daa5531,0x3ec0a217,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbed93924,0xbe4190b3,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f593924,0xa4e41e6a,0x00000000,0x3f800000,0x00000000,0x3f800000,
0x25800000,0x3ec190b3,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbec2e2b8,0xbe539b1a,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f582d5e,0x3d17c81c,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbdaa5531,0x3ec0a217,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbeaaabd2,0xbe639bcf,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f550ca0,0x3d970d02,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbe298338,0x3ebdd88f,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbe90d026,0xbe716b5e,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f4fdea1,0x3de0c18f,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbe7c39ed,0x3eb93afa,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbe6b1ee6,0xbe7ce7b9,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f48b025,0x3e1425fe,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbea64165,0x3eb2d4b9,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbe3259d5,0xbe82fa48,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f3f92e2,0x3e367df6,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbecccbef,0x3eaab594,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbdefba1c,0xbe863dc9,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f349d4f,0x3e571402,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbef15d91,0x3ea0f190,0x00000000,0x00000000,0x3f800000,0x3f800000,
0xbd70e30d,0xbe883654,0x3f800000,0x00000000,0x00000000,0x3f800000,
0x3f27ea72,0x3e7597cd,0x00000000,0x3f800000,0x00000000,0x3f800000,
0xbf09ce11,0x3e95a0c1,0x00000000,0x00000000,0x3f800000,0x3f800000
};

/*
 * CUBS GPU client (boot-arg cubs_gpu=1): Linux runs the GPU server (pcwork/gpusrv, metal2vulkan on the PowerVR) beside
 * XNU; the two talk through a ring in reserved RAM that XNU does not manage (PA cubs_gpu_pa, boot-arg cubs_gpu_pa=<hex>,
 * default 0xab2000000). This is the proof of concept of the Metal route: every 40 ms XNU asks the server for a frame of a
 * rotating triangle and pastes the pixels it gets back over the iOS display (540x1212 at 270,600).
 * Ring layout (see gpusrv/src/ring.rs): word 0 magic "GPU1", 1 request counter, 2 done counter, 3 w, 4 h, 5 vertex count,
 * 6 clear colour, 7 server microseconds; vertices (x y r g b a, f32) at +64; RGBA8 pixels at +65536.
 */
#define CUBS_GPU_MAGIC 0x47505531u
#define CUBS_GPU_W 360u
#define CUBS_GPU_H 808u
static uint64_t cubs_gpu_pa = 0xab2000000ULL;
static volatile uint8_t *cubs_gpu_ring;
static thread_call_t cubs_gpu_call;
static uint32_t cubs_gpu_wait, cubs_gpu_step, cubs_gpu_seq, cubs_gpu_frames, cubs_gpu_bad, cubs_gpu_dead;

static void
cubs_gpu_tick(__unused thread_call_param_t p0, __unused thread_call_param_t p1)
{
	volatile uint32_t *w;
	uint64_t deadline;

	if (cubs_gpu_dead) {
		return;
	}
	if (cubs_gpu_ring == NULL) {
		if (!cubs_blit_ready) {
			clock_interval_to_deadline(1000, NSEC_PER_MSEC, &deadline);
			thread_call_enter_delayed(cubs_gpu_call, deadline);
			return;
		}
		cubs_gpu_ring = (volatile uint8_t *)io_map(cubs_gpu_pa, 0x1000000, VM_WIMG_DEFAULT, VM_PROT_DEFAULT, false);
		if (cubs_gpu_ring == NULL) {
			printf("CUBS gpu: map of the ring at %llx failed\n", cubs_gpu_pa);
			cubs_gpu_dead = 1;
			return;
		}
		printf("CUBS gpu: ring mapped at %llx\n", cubs_gpu_pa);
	}
	w = (volatile uint32_t *)cubs_gpu_ring;
	FlushPoC_DcacheRegion((vm_offset_t)cubs_gpu_ring, 64);
	if (w[0] != CUBS_GPU_MAGIC) {
		if ((cubs_gpu_bad++ % 20) == 0) {
			printf("CUBS gpu: no server yet (magic %x)\n", w[0]);
		}
		clock_interval_to_deadline(1000, NSEC_PER_MSEC, &deadline);
		thread_call_enter_delayed(cubs_gpu_call, deadline);
		return;
	}
	if (!cubs_gpu_wait) {
		volatile uint32_t *v = (volatile uint32_t *)(cubs_gpu_ring + 64);
		const uint32_t *t = &cubs_gpu_tab[(cubs_gpu_step++ & 63) * 18];

		for (uint32_t i = 0; i < 18; i++) {
			v[i] = t[i];
		}
		w[3] = CUBS_GPU_W;
		w[4] = CUBS_GPU_H;
		w[5] = 3;
		w[6] = 0xff1a0d0d;
		__asm__ volatile ("dsb sy" ::: "memory");
		FlushPoC_DcacheRegion((vm_offset_t)cubs_gpu_ring, 64 + 18 * 4);
		cubs_gpu_seq = w[1] + 1;
		w[1] = cubs_gpu_seq;
		__asm__ volatile ("dsb sy" ::: "memory");
		FlushPoC_DcacheRegion((vm_offset_t)cubs_gpu_ring, 64);
		cubs_gpu_wait = 1;
		clock_interval_to_deadline(4, NSEC_PER_MSEC, &deadline);
		thread_call_enter_delayed(cubs_gpu_call, deadline);
		return;
	}
	FlushPoC_DcacheRegion((vm_offset_t)cubs_gpu_ring, 64);
	if (w[2] != cubs_gpu_seq) {
		if (++cubs_gpu_wait > 200) {    /* the server went away: ask again */
			cubs_gpu_wait = 0;
		}
		clock_interval_to_deadline(2, NSEC_PER_MSEC, &deadline);
		thread_call_enter_delayed(cubs_gpu_call, deadline);
		return;
	}
	cubs_gpu_wait = 0;
	{
		static uint64_t row[CUBS_GPU_W / 2];
		uint32_t cur = 0, ox = 0, oy = 0;
		const uint32_t *src;

		FlushPoC_DcacheRegion((vm_offset_t)(cubs_gpu_ring + 65536), CUBS_GPU_W * CUBS_GPU_H * 4);
		for (uint32_t y = 0; y < CUBS_GPU_H; y++) {
			src = (const uint32_t *)(cubs_gpu_ring + 65536 + (uint64_t)y * CUBS_GPU_W * 4);
			for (uint32_t x = 0; x < CUBS_GPU_W; x += 2) {
				uint32_t a = src[x], b = src[x + 1];

				a = (a & 0xff00ff00u) | ((a & 0xff) << 16) | ((a >> 16) & 0xff);   /* RGBA -> BGRA */
				b = (b & 0xff00ff00u) | ((b & 0xff) << 16) | ((b >> 16) & 0xff);
				row[x / 2] = ((uint64_t)b << 32) | a;
			}
			cubs_blit_put(&cur, (uint64_t)(oy + y) * cubs_blit_pitch + (uint64_t)ox * 4, row, CUBS_GPU_W * 4);
		}
	}
	cubs_gpu_dirty = 1;
	cubs_blit_frame_done();
	if ((++cubs_gpu_frames % 50) == 1) {
		printf("CUBS gpu: frame %u, server %u us\n", cubs_gpu_frames, w[7]);
	}
	clock_interval_to_deadline(80, NSEC_PER_MSEC, &deadline);
	thread_call_enter_delayed(cubs_gpu_call, deadline);
}

__startup_func
static void
cubs_gpu_init(void)
{
	uint64_t deadline, pa;
	uint32_t on = 0;

	if (!PE_parse_boot_argn("cubs_gpu", &on, sizeof(on)) || on == 0) {
		return;
	}
	if (PE_parse_boot_argn("cubs_gpu_pa", &pa, sizeof(pa)) && pa != 0) {
		cubs_gpu_pa = pa;
	}
	cubs_gpu_call = thread_call_allocate(cubs_gpu_tick, NULL);
	clock_interval_to_deadline(10, NSEC_PER_SEC, &deadline);
	thread_call_enter_delayed(cubs_gpu_call, deadline);
}
STARTUP(EARLY_BOOT, STARTUP_RANK_LAST, cubs_gpu_init);

/*
 * CUBS present (boot-arg cubs_present=1): the Metal RPC server (mtlsrv, op 11 PRESENT) leaves a rendered texture's RGBA8 pixels
 * at ring + 65536 and bumps a present counter in the Metal mailbox (ring + 0xB00000, words 8 counter, 9 w, 10 h, 11 x, 12 y).
 * This thread pastes them into the scan-out pages whenever the counter moves: what an iOS program renders through libmtlshim
 * and presents appears on the panel beside what iOS itself draws.
 */
static thread_call_t cubs_present_call;
static uint32_t cubs_present_last, cubs_present_frames;
static volatile uint8_t *cubs_present_ring;

static void
cubs_present_tick(__unused thread_call_param_t p0, __unused thread_call_param_t p1)
{
	static uint64_t row[540];
	volatile uint32_t *m;
	uint64_t deadline;

	if (cubs_present_ring == NULL) {
		if (cubs_blit_ready) {
			cubs_present_ring = (volatile uint8_t *)io_map(cubs_gpu_pa, 0x1000000, VM_WIMG_DEFAULT, VM_PROT_DEFAULT, false);
			printf("CUBS present: ring %p\n", (void *)cubs_present_ring);
		}
		clock_interval_to_deadline(1000, NSEC_PER_MSEC, &deadline);
		thread_call_enter_delayed(cubs_present_call, deadline);
		return;
	}
	m = (volatile uint32_t *)(cubs_present_ring + 0xB00000);
	FlushPoC_DcacheRegion((vm_offset_t)m, 64);
	if (m[0] == 0x4d544c31 && m[8] != cubs_present_last) {
		uint32_t w = m[9], h = m[10], ox = m[11], oy = m[12], cur = 0;

		if (w == 0 || w > 1080 || h == 0 || h > 2424 || (w & 1)) {
			cubs_present_last = m[8];
		} else {
			FlushPoC_DcacheRegion((vm_offset_t)(cubs_present_ring + 65536), (unsigned)(w * h * 4));
			for (uint32_t y = 0; y < h; y++) {
				const uint32_t *src = (const uint32_t *)(cubs_present_ring + 65536 + (uint64_t)y * w * 4);

				for (uint32_t x = 0; x < w; x += 2) {
					uint32_t a = src[x], b = src[x + 1];

					a = (a & 0xff00ff00u) | ((a & 0xff) << 16) | ((a >> 16) & 0xff);   /* RGBA -> BGRA */
					b = (b & 0xff00ff00u) | ((b & 0xff) << 16) | ((b >> 16) & 0xff);
					row[x / 2] = ((uint64_t)b << 32) | a;
				}
				cubs_blit_put(&cur, (uint64_t)(oy + y) * cubs_blit_pitch + (uint64_t)ox * 4, row, w * 4);
			}
			cubs_present_last = m[8];
			cubs_gpu_dirty = 1;
			cubs_blit_frame_done();
			if ((++cubs_present_frames % 20) == 1) {
				printf("CUBS present: frame %u (%ux%u at %u,%u)\n", cubs_present_frames, w, h, ox, oy);
			}
		}
	}
	clock_interval_to_deadline(25, NSEC_PER_MSEC, &deadline);
	thread_call_enter_delayed(cubs_present_call, deadline);
}

__startup_func
static void
cubs_present_init(void)
{
	uint64_t deadline, pa;
	uint32_t on = 0;

	if (!PE_parse_boot_argn("cubs_present", &on, sizeof(on)) || on == 0) {
		return;
	}
	if (PE_parse_boot_argn("cubs_gpu_pa", &pa, sizeof(pa)) && pa != 0) {
		cubs_gpu_pa = pa;
	}
	cubs_present_call = thread_call_allocate(cubs_present_tick, NULL);
	clock_interval_to_deadline(10, NSEC_PER_SEC, &deadline);
	thread_call_enter_delayed(cubs_present_call, deadline);
}
STARTUP(EARLY_BOOT, STARTUP_RANK_LAST, cubs_present_init);

/*
 * CUBS touch (boot-arg cubs_touch=1): the Pixel 11's Synaptics TCM touch controller (S3908) on the always-on DesignWare
 * SSI at 0xda2c000, polled. Chip select is the GPIO pin 23 and the interrupt line pin 54 of the always-on pinctrl
 * (one 4 KiB register page per pin at 0xe500000: +0x08 bit 2 is the output level, +0x1c bit 0 the input level). Linux
 * has left the chip in application mode with touch reports on and the controller powered (the hand-over script pins
 * the SPI and pinctrl devices' runtime PM "on"). A frame is: header read {0xa5, code, len lo, len hi}, then a
 * continued read of round16(len + 3) bytes {0xa5, 0x03, payload..., 0x5a}. Code 0xc6 is the touch frame: contact
 * count at byte 32 and 12-byte contacts from byte 34 {status, x, y, z, sizes[4], pad} (x 0..10799, y 0..24239).
 */
#include <kern/sched_prim.h>
extern void redwood_touch_post(uint32_t type, uint32_t finger, uint32_t x, uint32_t y);
extern uint32_t redwood_touch_backlog(void);
extern uint32_t redwood_touch_consumed(void);

#define CT_MAXC 10
#define CT_BUF  2112

static volatile uint32_t *ct_spi, *ct_cs, *ct_irq;
static uint8_t ct_tx[CT_BUF], ct_rx[CT_BUF];
static uint32_t ct_div = 32, ct_mode, ct_nframes, ct_ntouch;
static struct { uint32_t down, x, y; } ct_f[CT_MAXC];

#define CT_SSIENR 0x08
#define CT_SER 0x10
#define CT_BAUDR 0x14
#define CT_TXFTLR 0x18
#define CT_RXFTLR 0x1c
#define CT_SR 0x28
#define CT_DR 0x60

static inline uint32_t ct_r(uint32_t off) { return ct_spi[off / 4]; }
static inline void ct_w(uint32_t off, uint32_t v) { ct_spi[off / 4] = v; }

static void
ct_cs_set(int asserted)
{
	uint32_t v = ct_cs[0x08 / 4];

	v = asserted ? (v & ~4u) : (v | 4u);
	ct_cs[0x08 / 4] = v;
	__asm__ volatile ("dsb sy" ::: "memory");
	if (asserted) {
		delay_for_interval(10, 1000);
	}
}

/* one framed transfer: n bytes out (ct_tx) and in (ct_rx), 8-bit mode 0, polled */
static int
ct_xfer(uint32_t n)
{
	uint32_t itx = 0, irx = 0, spin = 0;

	ct_w(CT_SSIENR, 0);
	ct_w(0x00, 0x01070000);
	ct_w(CT_BAUDR, ct_div);
	ct_w(CT_TXFTLR, 0);
	ct_w(CT_RXFTLR, 0);
	ct_w(CT_SER, 1);
	ct_w(CT_SSIENR, 1);
	ct_cs_set(1);
	while (irx < n) {
		while (itx < n && (ct_r(CT_SR) & 2) && (itx - irx) < 8) {
			ct_w(CT_DR, ct_tx[itx++]);
		}
		while (ct_r(CT_SR) & 8) {
			ct_rx[irx++] = (uint8_t)ct_r(CT_DR);
			spin = 0;
		}
		if (++spin > 4000000) {
			ct_cs_set(0);
			ct_w(CT_SSIENR, 0);
			return -1;
		}
	}
	while (ct_r(CT_SR) & 1) {
		if (++spin > 4000000) {
			break;
		}
	}
	ct_cs_set(0);
	ct_w(CT_SSIENR, 0);
	return 0;
}

static void
ct_sleep_ms(uint32_t ms)
{
	assert_wait_timeout((event_t)&ct_sleep_ms, THREAD_UNINT, ms, NSEC_PER_MSEC);
	thread_block(THREAD_CONTINUE_NULL);
}

static void
ct_post(uint32_t type, uint32_t i, uint32_t x, uint32_t y)
{
	redwood_touch_post(type, i, (x * 65535u) / 10799u, (y * 65535u) / 24239u);
}

static void
ct_frame(uint32_t n)
{
	uint32_t i, cnt = ct_rx[32];

	if (ct_rx[0] != 0xa5 || ct_rx[1] != 0x03 || n < 34 || cnt > CT_MAXC) {
		return;
	}
	if (34 + 12 * cnt > n) {
		return;
	}
	for (i = 0; i < CT_MAXC; i++) {
		if (i < cnt) {
			const uint8_t *r = &ct_rx[34 + 12 * i];
			uint32_t x = r[1] | (r[2] << 8), y = r[3] | (r[4] << 8);
			if (x > 10799) { x = 10799; }
			if (y > 24239) { y = 24239; }
			if (!ct_f[i].down) {
				ct_f[i].down = 1; ct_f[i].x = x; ct_f[i].y = y;
				ct_post(1, i, x, y);
				ct_ntouch++;
			} else if (ct_f[i].x != x || ct_f[i].y != y) {
				ct_f[i].x = x; ct_f[i].y = y;
				ct_post(2, i, x, y);
			}
		} else if (ct_f[i].down) {
			ct_f[i].down = 0;
			ct_post(3, i, ct_f[i].x, ct_f[i].y);
		}
	}
}

static void
ct_poll_once(void)
{
	uint32_t len, rl, code;

	memset(ct_tx, 0, 4);
	if (ct_xfer(4) != 0) {
		return;
	}
	if (ct_mode >= 2 && ct_nframes < 6) {
		printf("CUBS touch: hdr 0x%08x\n", ct_rx[0] | (ct_rx[1] << 8) | (ct_rx[2] << 16) | ((uint32_t)ct_rx[3] << 24));
	}
	if (ct_rx[0] != 0xa5) {
		return;
	}
	code = ct_rx[1];
	len = ct_rx[2] | (ct_rx[3] << 8);
	if (len == 0) {
		return;
	}
	rl = ((len + 3) + 15) & ~15u;
	if (rl > CT_BUF) {
		return;
	}
	memset(ct_tx, 0, rl);
	if (ct_xfer(rl) != 0) {
		return;
	}
	ct_nframes++;
	if (code == 0xc6) {
		ct_frame(rl);
	}
}

/*
 * Buttons: the power key and the two volume keys are inputs of the same always-on pinctrl as the touch controller's chip select and interrupt (Linux's
 * gpio_keys: pins 114 power, 117 volume down, 118 volume up, active low, pulled up by Linux's pin state, which the hand-over leaves in place). Their input level
 * is bit 0 of the pin's register at +0x1c, one 4 KiB page per pin at 0xe500000. A key counts as changed when two reads 2 ms apart agree; one that reads as held
 * before it has been seen released is not believed. The side button is REDWOOD_BUTTON_LOCK, then volume up and down (sys/redwood_input.h, types 4 and 5).
 * Holding power and volume down for cb_hold_ms (boot-arg cubs_btn_hold, default 3000, 0 = off) asks for a return to Android: the kernel resets the system.
 */
/*
 * Return to Android: Linux keeps running beside XNU, so XNU asks it to reboot cleanly. It writes "BYE1" into word 0 of the page at ring + 0xFF0000 (the same
 * reserved RAM the GPU servers use, PA 0xab2000000 + 0xFF0000, which no server touches); a watcher started by the hand-over script on the Android side polls that
 * word and runs sync; reboot. After the reboot the phone comes up in Android as usual (iOS is started again on request).
 */
static void
cubs_return_to_android(void)
{
	volatile uint32_t *w = (volatile uint32_t *)io_map(0xab2000000ULL + 0xFF0000ULL, 0x1000, VM_WIMG_DEFAULT, VM_PROT_DEFAULT, false);

	if (w == NULL) {
		printf("CUBS buttons: cannot map the return page\n");
		return;
	}
	w[0] = 0x31455942;
	__asm__ volatile ("dsb sy" ::: "memory");
	FlushPoC_DcacheRegion((vm_offset_t)w, 64);
	printf("CUBS buttons: return to Android requested\n");
}

#define CB_N 3
static const struct { uint32_t pin, id; } cb_keys[CB_N] = { { 114, 1 }, { 118, 2 }, { 117, 3 } };
static volatile uint32_t *cb_reg[CB_N];
static uint32_t cb_state[CB_N], cb_seen_up[CB_N], cb_pending[CB_N], cb_ready, cb_hold_ms = 3000, cb_hold_start, cb_ticks;
static uint32_t cb_nevents, cb_selfpress, cb_power_post = 1, cb_bye_after;   /* boot-arg cubs_bye_after=S: ask for the return to Android S seconds after the buttons start (test aid) */   /* boot-arg cubs_power_post=0: the power key does not reach iOS (default 1: it does; with the wall clock set the wake works) (it sleeps the display, and the wake does not light the panel again) */   /* boot-arg cubs_selfpress=S: a power press every S seconds (test aid) */

extern ppnum_t pmap_find_phys(pmap_t pmap, addr64_t va);
static int
cb_uread(task_t t, uint64_t va, uint64_t *out)
{
	ppnum_t pn = pmap_find_phys(t->map->pmap, va);

	if (pn == 0) {
		return 0;
	}
	*out = *(volatile uint64_t *)phystokv(((uint64_t)pn << PAGE_SHIFT) | (va & PAGE_MASK));
	return 1;
}

static void
cb_ustack(task_t t, thread_t th, const char *nm, int pid)
{
	arm_saved_state_t *ss = th->machine.upcb;
	uint64_t pc, lr, fp, nfp, nlr;
	const uint64_t mask = 0x0000007fffffffffULL;
	char line[400];
	int n = 0, i;

	if (ss == NULL || !is_saved_state64(ss)) {
		return;
	}
	pc = get_saved_state_pc(ss);
	lr = get_saved_state_lr(ss);
	fp = get_saved_state_fp(ss);
	n = snprintf(line, sizeof line, "pc %#llx lr %#llx", pc & mask, lr & mask);
	for (i = 0; i < 12 && fp != 0 && (fp & 7) == 0 && n < (int)sizeof line - 24; i++) {
		if (!cb_uread(t, fp, &nfp) || !cb_uread(t, fp + 8, &nlr)) {
			break;
		}
		n += snprintf(line + n, sizeof line - (size_t)n, " %#llx", nlr & mask);
		if (nfp <= fp) {
			break;
		}
		fp = nfp;
	}
	printf("CUBS stack: %s[%d] th %p %s\n", nm, pid, th, line);
}

/* boot-arg cubs_threads_after=S: at S seconds (and 60 s later) say what the threads of mediaserverd, SpringBoard and backboardd wait for (debug aid for the audio-server freeze) */
extern queue_head_t tasks;
extern void proc_name(int pid, char *buf, int size);
extern int task_pid(task_t task);
extern vm_offset_t vm_kernel_slide;
static uint32_t cb_threads_after;

static void
cubs_threads_dump(void)
{
	task_t t;
	thread_t th;

	printf("CUBS threads: kernel slide %#lx\n", (unsigned long)vm_kernel_slide);
	queue_iterate(&tasks, t, task_t, tasks) {
		int pid = task_pid(t);
		char nm[40] = "?";

		proc_name(pid, nm, sizeof nm);
		if (strcmp(nm, "mediaserverd") && strcmp(nm, "SpringBoard") && strcmp(nm, "backboardd") && strncmp(nm, "launchd", 7) && strcmp(nm, "runningboardd") && strcmp(nm, "lsd")) {
			continue;
		}
		queue_iterate(&t->threads, th, thread_t, task_threads) {
			printf("CUBS threads: %s[%d] th %p state %#x ev %p cont %p hint %d\n", nm, pid, th, (unsigned)th->state, (void *)th->wait_event,
			    (void *)th->continuation, (int)th->block_hint);
			cb_ustack(t, th, nm, pid);
		}
	}
}

static void
cb_setup(void)
{
	uint32_t i;

	for (i = 0; i < CB_N; i++) {
		cb_reg[i] = (volatile uint32_t *)ml_io_map(0xe500000ULL + (uint64_t)cb_keys[i].pin * 0x1000ULL, 0x1000);
		if (cb_reg[i] == NULL) {
			printf("CUBS buttons: map of pin %u failed\n", cb_keys[i].pin);
			return;
		}
	}
	printf("CUBS buttons: levels power %u vol-up %u vol-down %u (1 = released)\n", cb_reg[0][0x1c / 4] & 1, cb_reg[1][0x1c / 4] & 1, cb_reg[2][0x1c / 4] & 1);
	cb_ready = 1;
}

static void
cb_poll(void)
{
	uint32_t i;

	if (!cb_ready) {
		return;
	}
	cb_ticks++;
	if (cb_threads_after && (cb_ticks == cb_threads_after * 500 || cb_ticks == (cb_threads_after + 60) * 500)) {
		cubs_threads_dump();
	}
	if (cb_bye_after && cb_ticks == cb_bye_after * 500) {
		printf("CUBS buttons: test return to Android\n");
		cubs_return_to_android();
	}
	if (cb_selfpress) {
		uint32_t ph = cb_ticks % (cb_selfpress * 500);

		if (cb_ticks >= cb_selfpress * 500 && ph == 0) {
			redwood_touch_post(4, 1, 0, 0);
			printf("CUBS buttons: selfpress down\n");
		} else if (cb_ticks >= cb_selfpress * 500 && ph == 75) {
			redwood_touch_post(5, 1, 0, 0);
			printf("CUBS buttons: selfpress up\n");
		}
	}
	for (i = 0; i < CB_N; i++) {
		uint32_t pressed = (cb_reg[i][0x1c / 4] & 1) == 0;

		if (pressed != cb_pending[i]) {
			printf("CUBS buttons: raw key %u level changed, now %s (reg 0x%x)\n", cb_keys[i].id, pressed ? "low" : "high", cb_reg[i][0x1c / 4]);
		}
		if (pressed == cb_pending[i]) {
			if (!pressed) {
				cb_seen_up[i] = 1;
			}
			if (pressed != cb_state[i] && (cb_seen_up[i] || !pressed)) {
				cb_state[i] = pressed;
				cb_nevents++;
				if (cb_keys[i].id != 1 || cb_power_post) {
					redwood_touch_post(pressed ? 4 : 5, cb_keys[i].id, 0, 0);
				}
				printf("CUBS buttons: key %u %s\n", cb_keys[i].id, pressed ? "down" : "up");
			}
		}
		cb_pending[i] = pressed;
	}
	/* power + volume down held: back to Android */
	if (cb_hold_ms && cb_state[0] && cb_state[2]) {
		if (cb_hold_start == 0) {
			cb_hold_start = cb_ticks;
		} else if ((cb_ticks - cb_hold_start) * 2 >= cb_hold_ms) {
			printf("CUBS buttons: power + volume down held, returning to Android\n");
			cb_hold_start = 0;
			cubs_return_to_android();
		}
	} else {
		cb_hold_start = 0;
	}
}

/*
 * The wall clock: XNU has no RTC here and starts in 1970, where no certificate is valid yet. ios_start.sh writes "TIME<seconds since 1970>" into the shared RAM
 * (PA 0xab2000000 + 0xFF1000) from Android's clock before it starts the servers; this reads it once, a few seconds after boot.
 */
static void
cubs_set_time(void)
{
	volatile uint8_t *t = (volatile uint8_t *)io_map(0xab2000000ULL + 0xFF1000ULL, 0x1000, VM_WIMG_DEFAULT, VM_PROT_DEFAULT, false);
	uint64_t secs = 0;
	uint32_t i;

	if (t == NULL) {
		return;
	}
	for (i = 0; i < 40; i++) {
		FlushPoC_DcacheRegion((vm_offset_t)t, 64);
		if (t[0] == 'T' && t[1] == 'I' && t[2] == 'M' && t[3] == 'E' && t[4] >= '0' && t[4] <= '9') {
			break;
		}
		delay_for_interval(500, 1000 * 1000);
	}
	if (i == 40) {
		printf("CUBS time: not given: %02x %02x %02x %02x %02x %02x %02x %02x\n", t[0], t[1], t[2], t[3], t[4], t[5], t[6], t[7]);
		return;
	}
	for (i = 4; i < 20 && t[i] >= '0' && t[i] <= '9'; i++) {
		secs = secs * 10 + (t[i] - '0');
	}
	if (secs > 1700000000ULL) {
		clock_set_calendar_microtime((clock_sec_t)secs, 0);
		printf("CUBS time: wall clock set to %llu\n", secs);
	}
}

static void
cubs_touch_thread(__unused void *arg, __unused wait_result_t wr)
{
	uint32_t last = 0, ticks = 0;

	cubs_set_time();
		ct_spi = (volatile uint32_t *)ml_io_map(0xda2c000ULL, 0x1000);
	ct_cs = (volatile uint32_t *)ml_io_map(0xe517000ULL, 0x1000);
	ct_irq = (volatile uint32_t *)ml_io_map(0xe536000ULL, 0x1000);
	if (ct_spi == NULL || ct_cs == NULL || ct_irq == NULL) {
		printf("CUBS touch: map failed\n");
		return;
	}
	printf("CUBS touch: start, ssi version 0x%x ctrlr0 0x%x enabled %u cs reg 0x%x irq level %u\n", ct_r(0x5c), ct_r(0),
	    ct_r(CT_SSIENR), ct_cs[0x08 / 4], ct_irq[0x1c / 4] & 1);
	cb_setup();
	for (;;) {
		cb_poll();
		if ((ct_irq[0x1c / 4] & 1) == 0) {
			ct_poll_once();
		} else {
			ct_sleep_ms(2);
		}
		if ((++ticks % 500) == 0) {
			if (ct_mode >= 2 || ct_nframes != last) {
				printf("CUBS touch: nfr 0x%x touches 0x%x backlog 0x%x read 0x%x\n", ct_nframes, ct_ntouch, redwood_touch_backlog(), redwood_touch_consumed() + 0x100);
			}
			last = ct_nframes;
		}
	}
}

static void
cubs_touch_start(__unused thread_call_param_t p0, __unused thread_call_param_t p1)
{
	thread_t th;

	kernel_thread_start(cubs_touch_thread, NULL, &th);
	thread_deallocate(th);
}

__startup_func
static void
cubs_touch_init(void)
{
	uint64_t deadline;
	thread_call_t call;

	if (!PE_parse_boot_argn("cubs_touch", &ct_mode, sizeof(ct_mode)) || ct_mode == 0) {
		return;
	}
	(void)PE_parse_boot_argn("cubs_touch_div", &ct_div, sizeof(ct_div));
	(void)PE_parse_boot_argn("cubs_power_post", &cb_power_post, sizeof(cb_power_post));
	(void)PE_parse_boot_argn("cubs_bye_after", &cb_bye_after, sizeof(cb_bye_after));
	(void)PE_parse_boot_argn("cubs_threads_after", &cb_threads_after, sizeof(cb_threads_after));
	(void)PE_parse_boot_argn("cubs_selfpress", &cb_selfpress, sizeof(cb_selfpress));
	(void)PE_parse_boot_argn("cubs_btn_hold", &cb_hold_ms, sizeof(cb_hold_ms));
	call = thread_call_allocate(cubs_touch_start, NULL);
	clock_interval_to_deadline(8, NSEC_PER_SEC, &deadline);
	thread_call_enter_delayed(call, deadline);
}
STARTUP(EARLY_BOOT, STARTUP_RANK_LAST, cubs_touch_init);
