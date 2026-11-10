"""Mac-side patch: replace cubs_dpu_probe() with an MBA-mailbox power-on probe.
Reads only the safe MBA registers, sends 4 power-on requests (sswrp_dpu, dpu_be, dpu_fe0, dpu_dsi0) to the CPM request client at
0xea60000, logs the responses from the response client at 0xea61000, and reads the DPU only if every request was acknowledged.
Output lines start with "CUBS mba". Run on the Mac:  python3 mba_probe_patch.py\n"""
import os, re, shutil

R = os.path.expanduser('~/unixnu-pixel11/hackios-upstream/xnu-src/xnu-8796.121.2/')
lr = R + 'osfmk/arm64/loader_return.c'

NEW = r'''
extern void delay_for_interval(uint32_t interval, uint32_t scale_factor);

void
cubs_dpu_probe(void) /* cubs_mba_probe_v2 */
{
	volatile uint32_t *sys = (volatile uint32_t *)ml_io_map(0xea50000ULL, 0x1000);
	volatile uint32_t *rq = (volatile uint32_t *)ml_io_map(0xea60000ULL, 0x1000);
	volatile uint32_t *rs = (volatile uint32_t *)ml_io_map(0xea61000ULL, 0x1000);
	unsigned o, k, got = 0, acked = 0;

	if (sys == NULL || rq == NULL || rs == NULL) {
		printf("CUBS mba map failed\n");
		return;
	}
	printf("CUBS mba syscon id 0x%x (expect 0x4d4241)\n", sys[0]);
	for (o = 0; o <= 0x4c; o += 4) {
		printf("CUBS mba sys 0x%x 0x%x\n", o, sys[o / 4]);
	}
	printf("CUBS mba rq 0x8 0x%x 0x10 0x%x rs 0x8 0x%x\n", rq[0x8 / 4], rq[0x10 / 4], rs[0x8 / 4]);
	for (o = 0x100; o < 0x140; o += 0x10) {
		printf("CUBS mba rs slot 0x%x: %x %x %x %x\n", o, rs[o / 4], rs[o / 4 + 1], rs[o / 4 + 2], rs[o / 4 + 3]);
	}
	printf("CUBS mba stage1 ack stale response\n");
	rs[0x8 / 4] = 1;
	__asm__ volatile ("dsb sy; isb" ::: "memory");
	printf("CUBS mba stage1 done rs8 0x%x\n", rs[0x8 / 4]);
	printf("CUBS mba stage2 write rq slot0 word0\n");
	rq[0x100 / 4] = 0xa0010014u;
	__asm__ volatile ("dsb sy; isb" ::: "memory");
	printf("CUBS mba stage2 done readback 0x%x\n", rq[0x100 / 4]);
	printf("CUBS mba stage3 write rq slot0 words1-3\n");
	rq[0x104 / 4] = 0x81580008u; rq[0x108 / 4] = 1; rq[0x10c / 4] = 0;
	__asm__ volatile ("dsb sy; isb" ::: "memory");
	printf("CUBS mba stage3 done %x %x %x\n", rq[0x104 / 4], rq[0x108 / 4], rq[0x10c / 4]);
	printf("CUBS mba stage4 doorbell\n");
	rq[0] = 1;
	__asm__ volatile ("dsb sy; isb" ::: "memory");
	printf("CUBS mba stage4 done rq8 0x%x rq10 0x%x\n", rq[0x8 / 4], rq[0x10 / 4]);
	for (k = 0; k < 600 && got < 2; k++) {
		if (rs[0x8 / 4] & 1) {
			for (o = 0x100; o < 0x140; o += 0x10) {
				printf("CUBS mba rs slot 0x%x: %x %x %x %x\n", o, rs[o / 4], rs[o / 4 + 1], rs[o / 4 + 2], rs[o / 4 + 3]);
			}
			rs[0x8 / 4] = 1;
			got++;
		} else {
			delay_for_interval(1000, 1000);
		}
	}
	printf("CUBS mba responses %u\n", got);
	acked = got ? 4 : 0;
	if (acked == 4) {
		volatile uint32_t *d = (volatile uint32_t *)ml_io_map(0xf600000ULL, 0x1000);
		printf("CUBS mba all acked, reading DPU\n");
		for (o = 0; o < 0x100; o += 4) {
			printf("CUBS mba dpu 0x%x 0x%x\n", o, d[o / 4]);
		}
	} else {
		printf("CUBS mba not all acked (%u/4), DPU not read\n", acked);
	}
}

'''

s = open(lr).read()
if 'cubs_mba_probe_v2' not in s:
    shutil.copy(lr, lr + '.pre-mbaprobe')
    m = re.search(r'void\ncubs_dpu_probe\(void\)[^\n]*\n\{.*?\n\}\n\n', s, re.S)
    assert m, 'old cubs_dpu_probe not found (apply tools/dpu_probe_patch.py first)'
    s = s[:m.start()] + NEW.lstrip('\n') + s[m.end():]
    open(lr, 'w').write(s)
print('patched')
