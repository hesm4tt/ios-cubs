/*
 * glpresent.c.inc (included by glsrv.c): GPU-side presentation (plan "make iOS rendering fast", Phase 2). Instead of reading the iOS framebuffer back and
 * having XNU copy it into the scanout pages, the server draws the iOS framebuffer texture (1125x2436, scaled) into one of two linear AHardwareBuffers
 * that are DRM framebuffers and page-flips it. Enabled by env GL_PRESENT=1 (rollback: unset it and boot with cubs_blit=1 again).
 * Needs: SurfaceFlinger + vendor.hwcomposer-3 stopped and no other DRM master (no drmfb2) -- ios_start.sh arranges that when GL_PRESENT=1.
 * A second EGL context in the same share group is used so the forwarded GL state of the client is never disturbed.
 */
#include <android/hardware_buffer.h>
#include <dlfcn.h>
#include <drm/drm.h>
#include <drm/drm_fourcc.h>
#include <drm/drm_mode.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2ext.h>

#define PR_W 1080
#define PR_H 2424

struct pr_nhandle { int version, numFds, numInts; int data[]; };

static struct {
	int ok, tried, fd, pending, cur;
	uint32_t crtc, conn, fbid[2];
	struct drm_mode_modeinfo mode;
	EGLContext ctx;
	EGLSurface surf;
	GLuint fbo[2], tex[2], prog, vao;
	GLint uloc;
	unsigned long frames, skipped;
	double t_draw, t_wait;
} pr;

static const char *pr_vs = "#version 300 es\nout vec2 uv; void main(){ vec2 p = vec2((gl_VertexID<<1)&2, gl_VertexID&2); uv = p; gl_Position = vec4(p*2.0-1.0, 0.0, 1.0); }\n";
/* the iOS framebuffer is stored top row first like its texture; the scanout buffer is top row first too, GL's y is up, so flip v */
static const char *pr_fs = "#version 300 es\nprecision mediump float; in vec2 uv; uniform sampler2D src; out vec4 o;\n"
	"void main(){ vec4 c = texture(src, vec2(uv.x, uv.y)); o = vec4(c.rgb, 1.0); }\n";

static int
pr_find_display(void)
{
	for (int i = 0; i < 4; i++) {
		char path[32];
		struct drm_mode_card_res res = { 0 };
		uint32_t crtcs[8], conns[8], encs[8];
		int f;

		snprintf(path, sizeof path, "/dev/dri/card%d", i);
		f = open(path, O_RDWR);
		if (f < 0 || ioctl(f, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
			if (f >= 0) {
				close(f);
			}
			continue;
		}
		res.crtc_id_ptr = (uintptr_t)crtcs;
		res.connector_id_ptr = (uintptr_t)conns;
		res.encoder_id_ptr = (uintptr_t)encs;
		res.fb_id_ptr = 0;
		res.count_fbs = 0;
		res.count_crtcs = res.count_crtcs > 8 ? 8 : res.count_crtcs;
		res.count_connectors = res.count_connectors > 8 ? 8 : res.count_connectors;
		res.count_encoders = res.count_encoders > 8 ? 8 : res.count_encoders;
		ioctl(f, DRM_IOCTL_MODE_GETRESOURCES, &res);
		for (uint32_t k = 0; k < res.count_connectors; k++) {
			struct drm_mode_get_connector c = { .connector_id = conns[k] };
			struct drm_mode_modeinfo modes[32];
			uint32_t cenc[8];

			ioctl(f, DRM_IOCTL_MODE_GETCONNECTOR, &c);
			c.count_modes = c.count_modes > 32 ? 32 : c.count_modes;
			c.modes_ptr = (uintptr_t)modes;
			c.count_encoders = c.count_encoders > 8 ? 8 : c.count_encoders;
			c.encoders_ptr = (uintptr_t)cenc;
			c.count_props = 0;
			c.props_ptr = 0;
			c.prop_values_ptr = 0;
			ioctl(f, DRM_IOCTL_MODE_GETCONNECTOR, &c);
			if (c.connection == 1 && c.count_modes > 0) {
				struct drm_mode_get_encoder e = { .encoder_id = c.encoder_id };

				ioctl(f, DRM_IOCTL_MODE_GETENCODER, &e);
				pr.mode = modes[0];
				pr.conn = c.connector_id;
				pr.crtc = e.crtc_id != 0 ? e.crtc_id : crtcs[0];
				pr.fd = f;
				return 1;
			}
		}
		close(f);
	}
	return 0;
}

/* once, on the first present; returns 1 when ready. Leaves the main context current. */
static int
pr_init(void)
{
	const EGLint cattr[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE };
	const EGLint pattr[] = { EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE }, xattr[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
	const EGLint iattr[] = { EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE };
	AHardwareBuffer_Desc d = { .width = PR_W, .height = PR_H, .layers = 1, .format = AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM,
		.usage = AHARDWAREBUFFER_USAGE_GPU_COLOR_OUTPUT | AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE | AHARDWAREBUFFER_USAGE_COMPOSER_OVERLAY |
			 AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN | AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN };
	const struct pr_nhandle *(*getnh)(const AHardwareBuffer *) = dlsym(RTLD_DEFAULT, "AHardwareBuffer_getNativeHandle");
	EGLConfig cfg;
	EGLint n = 0;
	EGLContext main_ctx = eglGetCurrentContext();
	EGLSurface main_surf = eglGetCurrentSurface(EGL_DRAW);

	if (pr.tried) {
		return pr.ok;
	}
	pr.tried = 1;
	if (getnh == NULL || !pr_find_display()) {
		printf("glsrv: present: no display / no getNativeHandle\n");
		return 0;
	}
	ioctl(pr.fd, DRM_IOCTL_SET_MASTER, 0);
	if (!eglChooseConfig(dpy, cattr, &cfg, 1, &n) || n < 1) {
		return 0;
	}
	pr.surf = eglCreatePbufferSurface(dpy, cfg, pattr);
	pr.ctx = eglCreateContext(dpy, cfg, main_ctx, xattr);
	if (pr.ctx == EGL_NO_CONTEXT || !eglMakeCurrent(dpy, pr.surf, pr.surf, pr.ctx)) {
		printf("glsrv: present: context failed %x\n", eglGetError());
		return 0;
	}
	PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC getbuf = (PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC)eglGetProcAddress("eglGetNativeClientBufferANDROID");
	PFNEGLCREATEIMAGEKHRPROC mkimg = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
	PFNGLEGLIMAGETARGETTEXTURE2DOESPROC target = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");

	for (int i = 0; i < 2; i++) {
		AHardwareBuffer *ahb;
		AHardwareBuffer_Desc got;

		if (AHardwareBuffer_allocate(&d, &ahb) != 0) {
			printf("glsrv: present: allocate %d failed\n", i);
			goto fail;
		}
		AHardwareBuffer_describe(ahb, &got);
		const struct pr_nhandle *nh = getnh(ahb);
		struct drm_prime_handle ph = { .fd = nh->data[0] };

		if (ioctl(pr.fd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &ph) < 0) {
			printf("glsrv: present: PRIME_FD_TO_HANDLE failed\n");
			goto fail;
		}
		struct drm_mode_fb_cmd2 fb = { .width = got.width, .height = got.height, .pixel_format = DRM_FORMAT_XBGR8888, .handles = { ph.handle },
			.pitches = { got.stride * 4 } };

		if (ioctl(pr.fd, DRM_IOCTL_MODE_ADDFB2, &fb) < 0) {
			printf("glsrv: present: ADDFB2 failed\n");
			goto fail;
		}
		pr.fbid[i] = fb.fb_id;
		EGLImageKHR img = mkimg(dpy, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, getbuf(ahb), iattr);

		glGenTextures(1, &pr.tex[i]);
		glBindTexture(GL_TEXTURE_2D, pr.tex[i]);
		target(GL_TEXTURE_2D, img);
		glGenFramebuffers(1, &pr.fbo[i]);
		glBindFramebuffer(GL_FRAMEBUFFER, pr.fbo[i]);
		glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, pr.tex[i], 0);
		if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
			printf("glsrv: present: fbo %d incomplete\n", i);
			goto fail;
		}
	}
	{
		GLuint v = glCreateShader(GL_VERTEX_SHADER), f = glCreateShader(GL_FRAGMENT_SHADER);

		pr.prog = glCreateProgram();
		glShaderSource(v, 1, &pr_vs, NULL);
		glCompileShader(v);
		glShaderSource(f, 1, &pr_fs, NULL);
		glCompileShader(f);
		glAttachShader(pr.prog, v);
		glAttachShader(pr.prog, f);
		glLinkProgram(pr.prog);
		glGenVertexArrays(1, &pr.vao);
		pr.uloc = glGetUniformLocation(pr.prog, "src");
	}
	/* first picture: black, then the panel is ours */
	glBindFramebuffer(GL_FRAMEBUFFER, pr.fbo[0]);
	glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT);
	glFinish();
	{
		struct drm_mode_crtc sc = { .crtc_id = pr.crtc, .fb_id = pr.fbid[0], .set_connectors_ptr = (uintptr_t)&pr.conn, .count_connectors = 1,
			.mode_valid = 1, .mode = pr.mode };

		if (ioctl(pr.fd, DRM_IOCTL_MODE_SETCRTC, &sc) < 0) {
			printf("glsrv: present: SETCRTC failed\n");
			goto fail;
		}
	}
	pr.cur = 0;
	pr.ok = 1;
	printf("glsrv: present: scanout ready, mode %ux%u@%u\n", pr.mode.hdisplay, pr.mode.vdisplay, pr.mode.vrefresh);
	fflush(stdout);
	eglMakeCurrent(dpy, main_surf, main_surf, main_ctx);
	return 1;
fail:
	eglMakeCurrent(dpy, main_surf, main_surf, main_ctx);
	return 0;
}

/* wait for the flip event of the previous present (so its buffer may be drawn into again) */
static void
pr_wait_flip(void)
{
	while (pr.pending) {
		char buf[256];
		ssize_t r = read(pr.fd, buf, sizeof buf);

		if (r <= 0) {
			pr.pending = 0;
			break;
		}
		for (ssize_t o = 0; o < r;) {
			struct drm_event *e = (struct drm_event *)(buf + o);

			if (e->type == DRM_EVENT_FLIP_COMPLETE) {
				pr.pending = 0;
			}
			o += e->length;
		}
	}
}

/* draw the iOS framebuffer texture (srctex, in the main context) scaled into the back buffer and flip */
static void
pr_present(GLuint srctex)
{
	EGLContext main_ctx = eglGetCurrentContext();
	EGLSurface main_surf = eglGetCurrentSurface(EGL_DRAW);
	double t0 = now(), t1;
	int next = pr.cur ^ 1;

	if (!pr.ok && !pr_init()) {
		return;
	}
	if (srctex == 0) {
		return;
	}
	glFlush();                                  /* the client's drawing into srctex must be submitted before the other context reads it */
	if (!eglMakeCurrent(dpy, pr.surf, pr.surf, pr.ctx)) {
		return;
	}
	pr_wait_flip();
	t1 = now();
	glBindFramebuffer(GL_FRAMEBUFFER, pr.fbo[next]);
	glViewport(0, 0, PR_W, PR_H);
	glDisable(GL_SCISSOR_TEST);
	glDisable(GL_BLEND);
	glDisable(GL_DEPTH_TEST);
	glUseProgram(pr.prog);
	glBindVertexArray(pr.vao);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, srctex);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glUniform1i(pr.uloc, 0);
	glDrawArrays(GL_TRIANGLES, 0, 3);
	glFinish();                                 /* the flip must not be issued before the GPU has finished the buffer: nothing attaches a fence to this dma-buf, the panel would scan a half drawn / older buffer (jitter, bounce back) */
	{
		struct drm_mode_crtc_page_flip pf = { .crtc_id = pr.crtc, .fb_id = pr.fbid[next], .flags = DRM_MODE_PAGE_FLIP_EVENT, .user_data = (uint64_t)next };

		if (ioctl(pr.fd, DRM_IOCTL_MODE_PAGE_FLIP, &pf) == 0) {
			pr.pending = 1;
			pr.cur = next;
		} else {
			pr.skipped++;
		}
	}
	pr.frames++;
	pr.t_wait += t1 - t0;
	pr.t_draw += now() - t1;
	eglMakeCurrent(dpy, main_surf, main_surf, main_ctx);
	if ((pr.frames % 100) == 0) {
		printf("glsrv: present: %lu frames (%lu skipped), flip wait %.2f ms, draw+flip %.2f ms per frame\n", pr.frames, pr.skipped,
		       pr.t_wait * 1000.0 / 100, pr.t_draw * 1000.0 / 100);
		pr.t_wait = pr.t_draw = 0;
		fflush(stdout);
	}
}
