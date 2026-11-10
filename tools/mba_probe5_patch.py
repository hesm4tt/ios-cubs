"""Mac-side: v5 - sweep all 8 request ring slots (CPM expects its own ring pointer; Linux used slot 4 in the trace)."""
import os
p = os.path.expanduser('~/unixnu-pixel11/hackios-upstream/xnu-src/xnu-8796.121.2/osfmk/arm64/loader_return.c')
s = open(p).read()
for a, b in [('try < 2 && got == 0', 'try < 8 && got == 0'),
             ('if (try) {\n\t\t\t\tw[0] = 0xa0020014u;', 'if (try) {\n\t\t\t\tw[0] = 0xa0000014u | ((try + 1) << 16);'),
             ('ms < 3000 && got == 0', 'ms < 400 && got == 0'),
             ('cubs_mba_probe_v4 ', 'cubs_mba_probe_v5 ')]:
    assert a in s, a
    s = s.replace(a, b)
open(p, 'w').write(s)
print('patched v5')
