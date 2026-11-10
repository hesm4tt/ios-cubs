#!/usr/bin/env python3
# patch_surf_mean.py (run on the Mac): the kernel's surface trace (MiniIOSurface.cpp, boot-arg surftrace_of=NAME) also tells, for a traced surface at
# every lookup from a port and every unlock, the mean of every 64th byte and how many of those bytes are not 0x10 (video black). "Not 0" cannot tell a
# 420v picture from the black fill (16s), the mean can. Backup: MiniIOSurface.cpp.pre-surfmean. Re-running does nothing if the patch is there.
import os, sys
p = os.path.expanduser('~/unixnu-pixel11/hackios-upstream/xnu-src/xnu-8796.121.2/iokit/Kernel/MiniIOSurface.cpp')
s = open(p).read()
if 'not 0x10' in s:
    print('already patched')
    sys.exit(0)
bak = p + '.pre-surfmean'
if not os.path.exists(bak):
    open(bak, 'w').write(s)

# lookup from a port
a = '''		uint32_t format = right->surface->info.pixelFormat, nonzero = 0, first = 0, middle = 0;'''
assert s.count(a) == 1
s = s.replace(a, a + '\n\t\tuint64_t bsum = 0;\n\t\tuint32_t bn = 0, not16 = 0;')
b = '''			nonzero += pixels[at] != 0 || pixels[at + 1] != 0 || pixels[at + 2] != 0 || pixels[at + 3] != 0;
		}
		if (pixels != NULL && size >= 8) {'''
assert s.count(b) == 1
s = s.replace(b, '''			nonzero += pixels[at] != 0 || pixels[at + 1] != 0 || pixels[at + 2] != 0 || pixels[at + 3] != 0;
			bsum += pixels[at];
			bn++;
			not16 += pixels[at] != 0x10;
		}
		if (pixels != NULL && size >= 8) {''')
c = '''"begin with a pixel that is not 0, the first %#010x, one in the middle %#010x\\n", procname, proc_selfpid(),'''
assert s.count(c) == 1
s = s.replace(c, '''"begin with a pixel that is not 0, the first %#010x, one in the middle %#010x; mean byte %u, %u of %u not 0x10\\n", procname, proc_selfpid(),''')
d = '''(int) (format >> 16 & 0xff), (int) (format >> 8 & 0xff), (int) (format & 0xff), ret, nonzero, size / 64, first, middle);'''
assert s.count(d) == 1
s = s.replace(d, '''(int) (format >> 16 & 0xff), (int) (format >> 8 & 0xff), (int) (format & 0xff), ret, nonzero, size / 64, first, middle,
		    bn != 0 ? (uint32_t) (bsum / bn) : 0, not16, bn);''')

# unlock
e = '''		uint32_t sid = (uint32_t) (uintptr_t) p1, nonzero = 0, total = 0, seed = 0;'''
assert s.count(e) == 1
s = s.replace(e, e + '\n\t\tuint64_t ubsum = 0;\n\t\tuint32_t unot16 = 0;')
f = '''				nonzero += px[at] != 0 || px[at + 1] != 0 || px[at + 2] != 0 || px[at + 3] != 0;
				total++;'''
assert s.count(f) == 1
s = s.replace(f, f + '\n\t\t\t\tubsum += px[at];\n\t\t\t\tunot16 += px[at] != 0x10;')
g = '''seed %u: of every 64 bytes %u of %u begin with a pixel that is not 0\\n",
			    procname, proc_selfpid(), sid, ref->surface->info.width, ref->surface->info.height, seed, nonzero, total);'''
assert s.count(g) == 1
s = s.replace(g, '''seed %u: of every 64 bytes %u of %u begin with a pixel that is not 0; mean byte %u, %u of %u not 0x10\\n",
			    procname, proc_selfpid(), sid, ref->surface->info.width, ref->surface->info.height, seed, nonzero, total,
			    total != 0 ? (uint32_t) (ubsum / total) : 0, unot16, total);''')
open(p, 'w').write(s)
print('patched')
