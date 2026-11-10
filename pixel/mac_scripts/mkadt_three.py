#!/usr/bin/env python3
"""Create an experimental 3-core tree from the proven 2-core tree."""
import copy
import struct
import sys
sys.path.insert(0, 'pcwork/references/ios-bluejay/tools')
import adt
root = adt.parse(adt.load(sys.argv[1]))[0]
def nodes(node):
    yield node
    for child in node.children:
        yield from nodes(child)
cpus = next(n for n in root.children if n.name == 'cpus')
assert [n.name for n in cpus.children] == ['cpu0', 'cpu1']
assert int.from_bytes(cpus.children[1].prop('reg'), 'little') == 0x500
used = {int.from_bytes(n.prop('AAPL,phandle'), 'little') for n in nodes(root) if n.prop('AAPL,phandle')}
phandle = max(used) + 1
new = copy.deepcopy(cpus.children[1])
values = {'name': b'cpu2\0', 'reg': struct.pack('<I', 0x400), 'cpu-id': struct.pack('<I', 2), 'AAPL,phandle': struct.pack('<I', phandle)}
new.props = [(name, flags, values.get(name, value)) for name, flags, value in new.props]
assert all(new.prop(k) == v for k, v in values.items())
cpus.children.append(new)
with open(sys.argv[2], 'wb') as out:
    out.write(adt.serialize(root))
print('iOS cores: boot CPU6, CPU5, CPU4; new phandle', phandle)
