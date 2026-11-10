#!/usr/bin/env python3
# patch_cam_meanlog.py (run on the Mac): makes mediaserverd's camera shim (userland/src/camera_device.c) say what is in the pictures it gives:
# every 60th picture of a moving-picture output, plane 0's mean and maximum (a "rendered picture N: plane0 mean M max X" line in the kernel log),
# so that "the ISP draws black" and "the picture is lost between mediaserverd and the app" can be told apart (camprobe sees the app's side).
# Backup: camera_device.c.pre-meanlog (created once). Re-running does nothing if the patch is there.
import os, sys
p = os.path.expanduser('~/unixnu-pixel11/hackios-upstream/userland/src/camera_device.c')
s = open(p).read()
if 'rendered picture' in s:
    print('already patched')
    sys.exit(0)
bak = p + '.pre-meanlog'
if not os.path.exists(bak):
    open(bak, 'w').write(s)
anchor = '\tCVPixelBufferUnlockBaseAddress(pb, 0);\n\tCVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey'
assert s.count(anchor) == 1
new = '''\tif (out->delivered % 60 == 0 && strcmp(out->name, "StillImage") != 0 && pf != PF_BGRA) {
		const uint8_t *yp = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
		size_t ystride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), yw = CVPixelBufferGetWidthOfPlane(pb, 0), yh = CVPixelBufferGetHeightOfPlane(pb, 0);
		unsigned long ysum = 0, yn = 0;
		unsigned ymax = 0;

		if (yp != NULL) {
			for (size_t yy = 0; yy < yh; yy += 8) {
				for (size_t xx = 0; xx < yw; xx += 8) {
					unsigned v = yp[yy * ystride + xx];

					ysum += v;
					yn++;
					ymax = v > ymax ? v : ymax;
				}
			}
		}
		say("%s: rendered picture %llu: plane0 mean %lu max %u (%lu samples)", out->name, (unsigned long long)out->delivered,
		    yn != 0 ? ysum / yn : 0, ymax, yn);
	}
'''
s = s.replace(anchor, new + anchor)
open(p, 'w').write(s)
print('patched')
