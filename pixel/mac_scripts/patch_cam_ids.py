#!/usr/bin/env python3
# patch_cam_ids.py (run on the Mac): the media shim's "rendered picture" line (patch_cam_meanlog.py) also says the picture's IOSurface id and
# is written for each of the first 4 pictures too, so that camprobe's "IOSurface id" (the app's side) can be compared with it.
import os, sys
p = os.path.expanduser('~/unixnu-pixel11/hackios-upstream/userland/src/camera_device.c')
s = open(p).read()
if 'rendered picture' not in s:
    print('patch_cam_meanlog.py first')
    sys.exit(1)
if 'IOSurface id' in s:
    print('already patched')
    sys.exit(0)
a = 'if (out->delivered % 60 == 0 && strcmp(out->name, "StillImage") != 0 && pf != PF_BGRA) {'
assert s.count(a) == 1
s = s.replace(a, 'if ((out->delivered % 60 == 0 || out->delivered < 4) && strcmp(out->name, "StillImage") != 0 && pf != PF_BGRA) {')
b = 'say("%s: rendered picture %llu: plane0 mean %lu max %u (%lu samples)", out->name, (unsigned long long)out->delivered,\n\t\t    yn != 0 ? ysum / yn : 0, ymax, yn);'
assert s.count(b) == 1, 'say line not found'
new = ('say("%s: rendered picture %llu: plane0 mean %lu max %u (%lu samples); IOSurface id %u (%zu bytes), buffer %p base %p", out->name,\n'
       '\t\t    (unsigned long long)out->delivered, yn != 0 ? ysum / yn : 0, ymax, yn,\n'
       '\t\t    CVPixelBufferGetIOSurface(pb) != NULL ? IOSurfaceGetID(CVPixelBufferGetIOSurface(pb)) : 0,\n'
       '\t\t    CVPixelBufferGetIOSurface(pb) != NULL ? IOSurfaceGetAllocSize(CVPixelBufferGetIOSurface(pb)) : (size_t)0, (void *)pb, (const void *)yp);')
s = s.replace(b, new)
open(p, 'w').write(s)
print('patched')
