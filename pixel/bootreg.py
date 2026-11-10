"""Set the ADT cpu0 node's reg (MPIDR affinity) so XNU's MPIDR->cpu number lookup finds the core it really runs on.
usage: python bootreg.py in.payload out.payload 0x600"""
import struct, sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'references', 'ios-bluejay', 'tools'))
import adt
src, dst, reg = sys.argv[1], sys.argv[2], int(sys.argv[3], 0)
d = bytearray(open(src, 'rb').read())
ao, asz = struct.unpack_from('<QQ', d, 0x20)
orig = bytes(d[ao:ao + asz])
root, _ = adt.parse(orig)
cpu0 = next(c for c in root.children if c.name == 'cpus').children[0]
for k, p in enumerate(cpu0.props):
    if p[0] == 'reg':
        cpu0.props[k] = (p[0], p[1], struct.pack('<I', reg))
io = next(c for c in root.children if c.name == 'arm-io')
gic = next(c for c in io.children if c.name == 'gic')
for k, p in enumerate(gic.props):
    if p[0] == 'reg':
        v = list(struct.unpack('<%dQ' % (len(p[2]) // 8), p[2]))
        v[3] = 0x200000     # eight redistributor frames at a 0x40000 stride
        gic.props[k] = (p[0], p[1], struct.pack('<%dQ' % len(v), *v))
new = adt.serialize(root)
assert len(new) == len(orig)
d[ao:ao + asz] = new
open(dst, 'wb').write(d)
print('cpu0 reg ->', hex(reg))
