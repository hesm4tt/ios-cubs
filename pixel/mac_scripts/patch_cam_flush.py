#!/usr/bin/env python3
# patch_cam_flush.py (run on the Mac): the media shim (userland/src/camera_device.c) cleans the data cache of a picture's planes after the ISP drew it
# (sys_dcache_flush) before it unlocks the buffer. Why: with the IOSurface ids equal on both sides, mediaserverd's own mapping showed the chart
# (plane 0 mean 99) while the kernel's view and the app's showed black (0x10101010): the writes may sit in the cache of a mapping whose cache
# attribute differs from the others'. Backup: camera_device.c.pre-flush. Re-running does nothing if the patch is there.
import os, sys
p = os.path.expanduser('~/unixnu-pixel11/hackios-upstream/userland/src/camera_device.c')
s = open(p).read()
if 'sys_dcache_flush' in s:
    print('already patched')
    sys.exit(0)
bak = p + '.pre-flush'
if not os.path.exists(bak):
    open(bak, 'w').write(s)
inc = '#include <math.h>\n'
assert s.count(inc) == 1
s = s.replace(inc, inc + '#include <libkern/OSCacheControl.h>\n')
anchor = '\tCVPixelBufferUnlockBaseAddress(pb, 0);\n\tCVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey'
assert s.count(anchor) == 1
new = ('\t{\n'
       '\t\tsize_t np = CVPixelBufferGetPlaneCount(pb);\n\n'
       '\t\tfor (size_t pl = 0; pl < (np != 0 ? np : 1); pl++) {\n'
       '\t\t\tvoid *pa = np != 0 ? CVPixelBufferGetBaseAddressOfPlane(pb, pl) : CVPixelBufferGetBaseAddress(pb);\n'
       '\t\t\tsize_t pbytes = (np != 0 ? CVPixelBufferGetBytesPerRowOfPlane(pb, pl) * CVPixelBufferGetHeightOfPlane(pb, pl) :\n'
       '\t\t\t    CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb));\n\n'
       '\t\t\tif (pa != NULL) {\n'
       '\t\t\t\tsys_dcache_flush(pa, pbytes);\n'
       '\t\t\t}\n'
       '\t\t}\n'
       '\t}\n')
s = s.replace(anchor, new + anchor)
open(p, 'w').write(s)
print('patched')
