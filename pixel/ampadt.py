"""Make CPU N the XNU boot core (ADT cpu state 'running') and patch the boot-args.
usage: python ampadt.py in.payload out.payload N 'cmdline'"""
import struct, sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'references', 'ios-bluejay', 'tools'))
import adt
src, dst, n, cmd = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
d = bytearray(open(src, 'rb').read())
ao, asz = struct.unpack_from('<QQ', d, 0x20)
orig = bytes(d[ao:ao + asz])
root, _ = adt.parse(orig)
cpus = next(c for c in root.children if c.name == 'cpus')
for i, c in enumerate(cpus.children):
    for k, p in enumerate(c.props):
        if p[0] == 'state':
            c.props[k] = (p[0], p[1], (b'running\0' if i == n else b'stopped\0'))
# XNU compares the ADT cpu id with MPIDR Aff0, and every core of this SoC has Aff0 = 0: give the boot core id 0
# (swap the id fields of node 0 and node n) so that start.s takes the boot path
if n != 0:
    a, b = cpus.children[0], cpus.children[n]
    for key in ('reg', 'cpu-id'):
        ka = next(k for k, p in enumerate(a.props) if p[0] == key)
        kb = next(k for k, p in enumerate(b.props) if p[0] == key)
        pa, pb = a.props[ka], b.props[kb]
        a.props[ka] = (pa[0], pa[1], pb[2])
        b.props[kb] = (pb[0], pb[1], pa[2])
new = adt.serialize(root)
assert len(new) == len(orig), (len(new), len(orig))
d[ao:ao + asz] = new
c = cmd.encode()
d[0x48:0x48 + 608] = c + b'\0' * (608 - len(c))
open(dst, 'wb').write(d)
print('boot cpu', n, 'cmdline', cmd)
