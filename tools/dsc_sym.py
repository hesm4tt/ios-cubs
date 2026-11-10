"""Symbolicate addresses against a split dyld shared cache (iOS 16, arm64).

usage: dsc_sym.py CACHE_DIR SLIDE ADDR [ADDR ...]   (ADDR/SLIDE hex; ADDR are runtime addresses)
       dsc_sym.py CACHE_DIR SLIDE -k LOGFILE          (symbolicate "CUBS ut:"/"CUBS uf:" lines)
"""
import bisect, os, re, struct, sys

d = sys.argv[1]
slide = int(sys.argv[2], 16)
main = os.path.join(d, 'dyld_shared_cache_arm64')
files = {}


def blob(path):
    if path not in files:
        files[path] = open(path, 'rb').read()
    return files[path]


mh = blob(main)
mapoff, mapcnt = struct.unpack_from('<II', mh, 0x10)
sub_off, sub_cnt = struct.unpack_from('<II', mh, 0x188)
img_off, img_cnt = struct.unpack_from('<II', mh, 0x1c0)
if img_off == 0:
    img_off, img_cnt = struct.unpack_from('<II', mh, 0x18)

maps = []  # (addr, size, fileoff, path)


def add_maps(path):
    b = blob(path)
    mo, mc = struct.unpack_from('<II', b, 0x10)
    for i in range(mc):
        a, s, o, _, _ = struct.unpack_from('<QQQII', b, mo + i * 32)
        maps.append((a, s, o, path))


add_maps(main)
for i in range(sub_cnt):
    ent = mh[sub_off + i * 56: sub_off + (i + 1) * 56]
    suffix = ent[24:56].split(b'\0')[0].decode()
    p = main + suffix
    if os.path.exists(p):
        add_maps(p)
maps.sort()


def read_va(va, n):
    for a, s, o, p in maps:
        if a <= va < a + s:
            b = blob(p)
            o2 = o + (va - a)
            return b[o2:o2 + n]
    return None


images = []
for i in range(img_cnt):
    addr, _, _, pathoff, _ = struct.unpack_from('<QQQII', mh, img_off + i * 32)
    path = mh[pathoff:mh.index(b'\0', pathoff)].decode()
    images.append((addr, path))
images.sort()
img_addrs = [a for a, _ in images]

symcache = {}


def image_syms(addr):
    if addr in symcache:
        return symcache[addr]
    hdr = read_va(addr, 0x4000)
    ncmds = struct.unpack_from('<I', hdr, 0x10)[0]
    off = 0x20
    link = None
    symoff = nsyms = stroff = 0
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', hdr, off)
        if cmd == 0x19:
            name = hdr[off + 8: off + 24].split(b'\0')[0]
            vmaddr, vmsize, fileoff = struct.unpack_from('<QQQ', hdr, off + 24)
            if name == b'__LINKEDIT':
                link = (vmaddr, fileoff)
        elif cmd == 0x2:
            symoff, nsyms, stroff, strsize = struct.unpack_from('<IIII', hdr, off + 8)
        off += size
    out = []
    if link and nsyms:
        sv = link[0] + (symoff - link[1])
        stv = link[0] + (stroff - link[1])
        raw = read_va(sv, nsyms * 16)
        if raw and len(raw) == nsyms * 16:
            for i in range(nsyms):
                strx, typ, sect, desc, val = struct.unpack_from('<IBBHQ', raw, i * 16)
                if (typ & 0xe) == 0xe and val:
                    nm = read_va(stv + strx, 200)
                    if nm:
                        out.append((val, nm.split(b'\0')[0].decode(errors='replace')))
    out.sort()
    symcache[addr] = out
    return out


def sym(rt):
    a = rt - slide
    i = bisect.bisect_right(img_addrs, a) - 1
    if i < 0:
        return '?'
    base, path = images[i]
    syms = image_syms(base)
    if syms:
        j = bisect.bisect_right([v for v, _ in syms], a) - 1
        if j >= 0:
            return '%s  %s+0x%x' % (os.path.basename(path), syms[j][1], a - syms[j][0])
    return '%s+0x%x' % (os.path.basename(path), a - base)


if sys.argv[3] == '-k':
    cur = None
    for line in open(sys.argv[4], errors='replace'):
        m = re.search(r'CUBS ut: (\S+) th (\S+) .* pc (0x\w+) lr (0x\w+)', line)
        if m:
            print('\n== %s th %s' % (m.group(1), m.group(2)))
            print('  pc  %s' % sym(int(m.group(3), 16)))
            print('  lr  %s' % sym(int(m.group(4), 16)))
            continue
        m = re.search(r'CUBS uf: (\S+) th (\S+) #(\d+) (0x\w+)', line)
        if m:
            print('  #%-2s %s' % (m.group(3), sym(int(m.group(4), 16))))
else:
    for x in sys.argv[3:]:
        print(x, sym(int(x, 16)))
