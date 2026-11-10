"""Mac-side patch: add cubs_dpu_probe() (read-only dump of DPU / GPCSR / DSI registers) to the kernel
and call it from bsd_init.c just before cubs_dump_user(). Output lines: "CUBS dpu <block> 0xOFF 0xVAL" (non-zero words only).
Run on the Mac:  python3 dpu_probe_patch.py
"""
import os, re, shutil

R = os.path.expanduser('~/unixnu-pixel11/hackios-upstream/xnu-src/xnu-8796.121.2/')
lr, bi = R + 'osfmk/arm64/loader_return.c', R + 'bsd/kern/bsd_init.c'

PROBE = r'''
void
cubs_dpu_probe(void)
{
	static const struct { uint64_t pa; uint32_t len; const char *n; } rg[] = {
		{ 0xf600000ULL, 0x8000, "dpu" },
		{ 0xf790000ULL, 0x400, "gpcsr0" },
		{ 0xf79e000ULL, 0x4000, "gpcsr1" },
		{ 0xf7d8000ULL, 0x400, "dsi" },
	};
	unsigned i, o, lines = 0;

	for (i = 0; i < sizeof(rg) / sizeof(rg[0]); i++) {
		volatile uint32_t *b = (volatile uint32_t *)ml_io_map(rg[i].pa, rg[i].len);
		if (b == NULL) {
			printf("CUBS dpu %s map failed\n", rg[i].n);
			continue;
		}
		printf("CUBS dpu %s begin pa 0x%llx len 0x%x\n", rg[i].n, rg[i].pa, rg[i].len);
		for (o = 0; o < rg[i].len / 4 && lines < 4000; o++) {
			uint32_t v = b[o];
			if (v != 0) {
				printf("CUBS dpu %s 0x%x 0x%x\n", rg[i].n, o * 4, v);
				lines++;
			}
		}
		printf("CUBS dpu %s end\n", rg[i].n);
	}
}

'''

s = open(lr).read()
if 'cubs_dpu_probe' not in s:
    shutil.copy(lr, lr + '.pre-dpuprobe')
    a = 'void\nloader_return(void)\n{'
    assert a in s, 'anchor missing in loader_return.c'
    s = s.replace(a, PROBE + a, 1)
    open(lr, 'w').write(s)

b = open(bi).read()
if 'cubs_dpu_probe' not in b:
    shutil.copy(bi, bi + '.pre-dpuprobe')
    call = '{ extern void cubs_dpu_probe(void); cubs_dpu_probe(); } '
    b2 = re.sub(r'(\{ extern void cubs_dump_user\(void\); cubs_dump_user\(\); \})', call + r'\1', b, count=1)
    assert b2 != b, 'cubs_dump_user call missing in bsd_init.c (apply the ustack patch first)'
    open(bi, 'w').write(b2)
print('patched')
