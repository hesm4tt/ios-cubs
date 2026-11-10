"""Mac-side: v4 mailbox probe tail. Replaces the doorbell/wait part of cubs_dpu_probe (v3) with the exact Linux sequence
(doorbell, +0x8=0x100, read +0x10), a 3 s watch of rq/rs status, then a retry on ring slot 1. Run on the Mac after the v3 patch."""
import os
p = os.path.expanduser('~/unixnu-pixel11/hackios-upstream/xnu-src/xnu-8796.121.2/osfmk/arm64/loader_return.c')
s = open(p).read()
a = s.index('\tprintf("CUBS mba stage4 doorbell')
b = s.index('\tacked = got ? 4 : 0;')
NEW = r'''	{
		unsigned try, ms;
		uint32_t last8 = 0xffffffffu, last10 = 0xffffffffu, lrs = 0xffffffffu;
		for (try = 0; try < 2 && got == 0; try++) {
			volatile uint32_t *w = rq + (0x100 + 0x10 * try) / 4;
			if (try) {
				w[0] = 0xa0020014u; w[1] = 0x81580008u; w[2] = 1; w[3] = 0;
			}
			__asm__ volatile ("dsb sy; isb" ::: "memory");
			printf("CUBS mba try %u doorbell\n", try);
			rq[0] = 1;
			(void)rq[0x8 / 4];
			rq[0x8 / 4] = 0x100;
			printf("CUBS mba try %u after: rq8 0x%x rq10 0x%x rs8 0x%x\n", try, rq[0x8 / 4], rq[0x10 / 4], rs[0x8 / 4]);
			for (ms = 0; ms < 3000 && got == 0; ms++) {
				uint32_t a8 = rq[0x8 / 4], a10 = rq[0x10 / 4], r8 = rs[0x8 / 4];
				if (a8 != last8 || a10 != last10 || r8 != lrs) {
					printf("CUBS mba t=%u ms rq8 0x%x rq10 0x%x rs8 0x%x\n", ms, a8, a10, r8);
					last8 = a8; last10 = a10; lrs = r8;
				}
				if (r8 & 1) {
					for (o = 0x100; o < 0x140; o += 0x10) {
						printf("CUBS mba rs slot 0x%x: %x %x %x %x\n", o, rs[o / 4], rs[o / 4 + 1], rs[o / 4 + 2], rs[o / 4 + 3]);
					}
					rs[0x8 / 4] = 1;
					got++;
				} else {
					delay_for_interval(1000, 1000);
				}
			}
		}
	}
	printf("CUBS mba responses %u\n", got);
'''
s = s[:a] + NEW + s[b:]
s = s.replace('cubs_mba_probe_v3 ', 'cubs_mba_probe_v4 ')
open(p, 'w').write(s)
print('patched v4')
