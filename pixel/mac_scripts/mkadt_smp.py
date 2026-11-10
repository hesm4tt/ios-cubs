# ho.adt -> ho_smp.adt: the cores XNU may use are our boot core (cpu0 node, running) and Android's CPU7 (cpu1 node, reg 0x500, stopped)
import sys, struct
sys.path.insert(0, '.')
import adt
buf = adt.load(sys.argv[1])
root = adt.parse(buf)[0] if isinstance(adt.parse(buf), tuple) else adt.parse(buf)
def find(n, name):
    for c in n.children:
        if c.name == name:
            return c
cpus = find(root, 'cpus')
keep = [c for c in cpus.children if c.name in ('cpu0', 'cpu1')]
c1 = keep[1]
c1.props = [(n, f, (struct.pack('<I', 0x500) if n == 'reg' else v)) for n, f, v in c1.props]
cpus.children = keep
open(sys.argv[2], 'wb').write(adt.serialize(root))
print('ok', [c.name for c in cpus.children])
