import sys,re,struct,lz4.block
# usage: patch_wake_filter.py src.img dst.img cubs_replay.h  -> turns wake messages of class 0x...0802 into skipped no-ops
src,dst,hdr=sys.argv[1:4]
img=bytearray(open(src,'rb').read())
ksz=struct.unpack_from('<I',img,8)[0]
assert struct.unpack_from('<I',img,4096)[0]==0x184c2102
blocks=[];end=4096+4
while end<4096+ksz:
    n=struct.unpack_from('<I',img,end)[0]; end+=4
    blocks.append(lz4.block.decompress(bytes(img[end:end+n]),uncompressed_size=8<<20)); end+=n
raw=bytearray(b''.join(blocks))
txt=open(hdr).read()
tab=txt[txt.index('cubs_wake[]'):]
ents=re.findall(r'\{ (\d+), (\d), 0x([0-9a-f]+)ULL, 0x([0-9a-f]+)u, (\d+) \}',tab)
pats={}
for us,k,a,v,w in ents:
    if k!='1': continue
    a=int(a,16)
    if ((a>>32)&0xffff)==0x0802:
        old=struct.pack('<IIQII',int(us),1,a,int(v,16),int(w))
        new=struct.pack('<IIQII',int(us),0,1,int(v,16),int(w))
        pats[old]=new
print('patterns',len(pats))
tot=0
for old,new in pats.items():
    c=raw.count(old); tot+=c
    raw=raw.replace(old,new)
print('replaced',tot)
out=struct.pack('<I',0x184c2102)
for i in range(0,len(raw),8<<20):
    c=lz4.block.compress(bytes(raw[i:i+(8<<20)]),mode='high_compression',compression=12,store_size=False)
    out+=struct.pack('<I',len(c))+c
old_end=4096+ksz
assert 4096+len(out)<=old_end+(len(img)-old_end),'too big'
img[4096:4096+len(out)]=out
if 4096+len(out)<old_end: img[4096+len(out):old_end]=bytes(old_end-4096-len(out))
struct.pack_into('<I',img,8,len(out))
open(dst,'wb').write(img); print('ok',len(out),ksz)
