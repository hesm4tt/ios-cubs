"""Mac-side patch: replace cubs_dpu_probe() with an MBA-mailbox power-on probe.
Reads only the safe MBA registers, sends 4 power-on requests (sswrp_dpu, dpu_be, dpu_fe0, dpu_dsi0) to the CPM request client at
0xea60000, logs the responses from the response client at 0xea61000, and reads the DPU only if every request was acknowledged.
Output lines start with "CUBS mba". Run on the Mac:  python3 mba_probe_patch.py
"""
import os, re, shutil

R = os.path.expanduser('~/unixnu-pixel11/hackios-upstream/xnu-src/xnu-8796.121.2/')
lr = R + 'osfmk/arm64/loader_return.c'

NEW = r'''
extern void delay_for_interval(uint32_t interval, uint32_t scale_factor);

void
cubs_dpu_probe(void) /* cubs_mba_probe_v1 */
{
	volatile uint32_t *sys = (volatile uint32_t *)ml_io_map(0xea50000ULL, 0x1000);
	volatile uint32_t *rq = (volatile uint32_t *)ml_io_map(0xea60000ULL, 0x1000);
	volatile uint32_t *rs = (volatile uint32_t *)ml_io_map(0xea61000ULL, 0x1000);
	static const struct { uint32_t res; const char *n; } pd[] = {
		{ 0x08, "sswrp_dpu" }, { 0x27, "dpu_be" }, { 0x28, "dpu_fe0" }, { 0x2a, "dpu_dsi0" },
	};
	unsigned i, o, k, idx = 0, seq = 1, acked = 0;

	if (sys == NULL || rq == NULL || rs == NULL) {
		printf("CUBS mba map failed\n");
		return;
	}
	printf("CUBS mba syscon id 0x%x (expect 0x4d4241)\n", sys[0]);
	for (o = 0; o <= 0x4c; o += 4) {
		printf("CUBS mba sys 0x%x 0x%x\n", o, sys[o / 4]);
	}
	printf("CUBS mba rq 0x8 0x%x 0x10 0x%x rs 0x8 0x%x\n", rq[0x8 / 4], rq[0x10 / 4], rs[0x8 / 4]);
	for (o = 0x100; o < 0x180; o += 0x10) {
		printf("CUBS mba rs slot 0x%x: %x %x %x %x\n", o, rs[o / 4], rs[o / 4 + 1], rs[o / 4 + 2], rs[o / 4 + 3]);
	}
	for (i = 0; i < sizeof(pd) / sizeof(pd[0]); i++) {
		volatile uint32_t *w = rq + (0x100 + 0x10 * (idx & 7)) / 4;
		uint32_t got = 0;

		w[0] = 0xa0000014u | (seq << 16);
		w[1] = 0x81580000u | pd[i].res;
		w[2] = 1;
		w[3] = 0;
		__asm__ volatile ("dsb sy" ::: "memory");
		rq[0] = 1;
		(void)rq[0x8 / 4];
		rq[0x8 / 4] = 0x100;
		(void)rq[0x10 / 4];
		printf("CUBS mba sent %s idx %u seq %u\n", pd[i].n, idx, seq);
		idx++;
		seq++;
		for (k = 0; k < 600 && got < 2; k++) {
			uint32_t st = rs[0x8 / 4];
			if (st & 1) {
				for (o = 0x100; o < 0x180; o += 0x10) {
					printf("CUBS mba rs slot 0x%x: %x %x %x %x\n", o, rs[o / 4], rs[o / 4 + 1], rs[o / 4 + 2], rs[o / 4 + 3]);
				}
				rs[0x8 / 4] = 1;
				got++;
			} else {
				delay_for_interval(1000, 1000); /* 1 ms */
			}
		}
		printf("CUBS mba %s responses %u\n", pd[i].n, got);
		if (got) {
			acked++;
		}
	}
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
if 'cubs_mba_probe_v1' not in s:
    shutil.copy(lr, lr + '.pre-mbaprobe')
    m = re.search(r'void\ncubs_dpu_probe\(void\)\n\{.*?\n\}\n\n', s, re.S)
    assert m, 'old cubs_dpu_probe not found (apply tools/dpu_probe_patch.py first)'
    s = s[:m.start()] + NEW.lstrip('\n') + s[m.end():]
    open(lr, 'w').write(s)
print('patched')
