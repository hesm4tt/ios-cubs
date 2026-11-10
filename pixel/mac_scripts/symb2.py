import struct, re, bisect
p='$HOME/unixnu-pixel11/hackios-upstream/ios165/20F66__iPhone10,3_6/dyld_shared_cache_arm64'
f=open(p,'rb'); h=f.read(0x2000)
io,ic=struct.unpack_from('<II',h,0x18)
if ic==0: io,ic=struct.unpack_from('<II',h,0x1c0)
f.seek(io); raw=f.read(ic*32); imgs=[]
for i in range(ic):
    addr,mt,ino,po,pad=struct.unpack_from('<QQQII',raw,i*32)
    f.seek(po); imgs.append((addr,f.read(200).split(b'\0')[0].decode()))
imgs.sort(); addrs=[a for a,_ in imgs]
lsk=[a for a,n in imgs if n.endswith('libsystem_kernel.dylib')][0]
print('libsystem_kernel at',hex(lsk))
rows=[]
for line in open('/tmp/stk_lines.txt'):
    m=re.search(r'(mediaserverd|SpringBoard)\[\d+\] th (\S+) pc (\S+) lr (.*)$',line)
    if m:
        vals=[]
        for x in [m.group(3)]+m.group(4).split():
            try: vals.append(int(x,16))
            except: pass
        rows.append((m.group(1),m.group(2)[-6:],vals))
pc0=rows[0][2][0]
def where(a,s):
    i=bisect.bisect_right(addrs,a-s)-1
    return '%s+%#x'%(imgs[i][1].split('/')[-1],a-s-imgs[i][0])
base=(pc0-lsk)&~0x3fff
for k in range(0,12):
    s=base-k*0x4000
    nm=where(pc0,s)
    if 'libsystem_kernel' in nm:
        print('slide',hex(s),'pc ->',nm, '| lr1 ->', where(rows[0][2][1],s), where(rows[0][2][2],s))
        slide=s
        break
for who,th,vals in rows:
    print(who,th,' <- '.join(where(v,slide) for v in vals[:8]))
