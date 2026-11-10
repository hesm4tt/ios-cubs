import sys,struct,lz4.block
src,dst,old,new=sys.argv[1:5]
img=bytearray(open(src,'rb').read())
ksz=struct.unpack_from('<I',img,8)[0]
p=4096+4
assert struct.unpack_from('<I',img,4096)[0]==0x184c2102
blocks=[]
end=4096+4
while end<4096+ksz:
    n=struct.unpack_from('<I',img,end)[0]; end+=4
    blocks.append(lz4.block.decompress(bytes(img[end:end+n]),uncompressed_size=8<<20)); end+=n
raw=b''.join(blocks); 
print(len(blocks),len(raw))
o=old.encode();assert raw.count(o)==1
raw=raw.replace(o,new.encode())
out=struct.pack('<I',0x184c2102)
for i in range(0,len(raw),8<<20):
    c=lz4.block.compress(raw[i:i+(8<<20)],mode='high_compression',compression=12,store_size=False)
    out+=struct.pack('<I',len(c))+c
old_end=4096+ksz
assert 4096+len(out)<=old_end+ (len(img)-old_end), 'too big'
img[4096:4096+len(out)]=out
if 4096+len(out)<old_end: img[4096+len(out):old_end]=bytes(old_end-4096-len(out))
struct.pack_into('<I',img,8,len(out))
open(dst,'wb').write(img)
print('ok',len(out),ksz)
