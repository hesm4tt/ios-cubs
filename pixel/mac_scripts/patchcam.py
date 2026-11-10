import re
p='$HOME/unixnu-pixel11/hackios-upstream/xnu-src/xnu-8796.121.2/bsd/dev/redwood_camera.c'
s=open(p).read()
if 'bridge_fill' in s:
    print('already patched'); raise SystemExit
bridge='''
/*
 * cam_bridge=1 (with cam=5 cam_fake=1): the frames are the Android phone's own camera's. The app com.cubs.cam sends them to camsrv, which makes RAW10 of them in the
 * sensor's size and Bayer order that this file says (the request at +0x800 of the shared RAM at PA 0xab2000000 + 0x1100000: "CAMQ", width, height, bayer, stride)
 * and leaves it there ("CAMR", sequence, width, height, length; the picture at +0x1000). The chart stays until the first frame is there.
 */
extern void *io_map(vm_map_offset_t phys_addr, vm_size_t size, unsigned int flags, vm_prot_t prot, bool unmappable);
extern void FlushPoC_DcacheRegion(vm_offset_t va, unsigned length);
#define CBR_PA 0xab3100000ULL
#define CBR_SIZE 0xF00000
static volatile uint8_t *cbr;
static uint32_t cbr_frames;

static bool
bridge_fill(int p)
{
	uint32_t w = ios_mode->width, h = ios_mode->height, stride = RAW10_STRIDE(w);
	uint64_t need = (uint64_t)stride * h;
	volatile uint32_t *rq, *hd;
	uint32_t seq;

	if (cbr == NULL) {
		cbr = (volatile uint8_t *)io_map(CBR_PA, CBR_SIZE, VM_WIMG_DEFAULT, VM_PROT_DEFAULT, false);
		if (cbr == NULL) {
			return false;
		}
	}
	rq = (volatile uint32_t *)(cbr + 0x800);
	hd = (volatile uint32_t *)cbr;
	rq[1] = w;
	rq[2] = h;
	rq[3] = hw->bayer & 3;
	rq[4] = stride;
	__asm__ volatile ("dsb sy" ::: "memory");
	rq[0] = 0x51414d43;
	FlushPoC_DcacheRegion((vm_offset_t)(cbr + 0x800), 64);
	FlushPoC_DcacheRegion((vm_offset_t)cbr, 64);
	if (hd[0] != 0x52414d43 || hd[2] != w || hd[3] != h || hd[4] != need || need + 0x1000 > CBR_SIZE) {
		return false;
	}
	seq = hd[1];
	FlushPoC_DcacheRegion((vm_offset_t)(cbr + 0x1000), (unsigned)need);
	memcpy((uint8_t *)(ring + (uint64_t)p * ring_place_bytes), (const void *)(cbr + 0x1000), need);
	FlushPoC_DcacheRegion((vm_offset_t)cbr, 64);
	if (hd[1] != seq) {
		return false;
	}
	if ((cbr_frames++ % 60) == 0) {
		say("camera: bridge: frame %u from Android (%ux%u)\n", seq, w, h);
	}
	return true;
}
'''
marker='/* a session of cam_fake: ios_session()'
assert marker in s
s=s.replace(marker,bridge+'\n'+marker,1)
old='''		if (filled_lines[p] != ios_now.lines || filled_gain[p] != ios_now.gain) {
			fake_fill(p, ios_now.lines, ios_now.gain);
			filled_lines[p] = ios_now.lines;
			filled_gain[p] = ios_now.gain;
		}
		lck_mtx_lock(&ios_lock);
		place[p].state = PLACE_READY;'''
assert old in s
new='''		if (cam_bridge_on && bridge_fill(p)) {
			filled_lines[p] = 0;
		} else if (filled_lines[p] != ios_now.lines || filled_gain[p] != ios_now.gain) {
			fake_fill(p, ios_now.lines, ios_now.gain);
			filled_lines[p] = ios_now.lines;
			filled_gain[p] = ios_now.gain;
		}
		lck_mtx_lock(&ios_lock);
		place[p].state = PLACE_READY;'''
s=s.replace(old,new,1)
s=s.replace('\t(void)PE_parse_boot_argn("cam_fake_fps", &fps, sizeof(fps));','\t(void)PE_parse_boot_argn("cam_fake_fps", &fps, sizeof(fps));\n\t(void)PE_parse_boot_argn("cam_bridge", &cam_bridge_on, sizeof(cam_bridge_on));',1)
s=s.replace('static bool fake;\n','static bool fake;\nstatic uint32_t cam_bridge_on;\n',1)
open(p,'w').write(s)
print('patched')
