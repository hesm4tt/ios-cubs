/*
 * gpuflip: Spike A2 (plan "make iOS rendering fast"): can the GPU render into scanout buffers and the panel follow with page flips at full speed,
 * with SurfaceFlinger stopped? Two linear AHardwareBuffers (1080x2424 XBGR) wrapped as DRM framebuffers; each frame GLES (ANGLE on the PowerVR)
 * draws a full-screen gradient with a moving white bar into the next buffer, then DRM_IOCTL_MODE_PAGE_FLIP; the flip-complete event paces the loop.
 * Prints the GPU time per frame (draw + glFinish) and the flip interval statistics. The user watches the bar: smooth = it works.
 *   gpuflip [seconds]      (as root, after "stop surfaceflinger; stop vendor.hwcomposer-3"; gpuprobe_scan-style wrapper restarts them)
 * Built with the NDK: $T/bin/aarch64-linux-android31-clang -O2 -o gpuflip gpuflip.c -lEGL -lGLESv3 -lnativewindow -ldl
 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl32.h>
#include <GLES2/gl2ext.h>
#include <android/hardware_buffer.h>
#include <dlfcn.h>
#include <drm/drm.h>
#include <drm/drm_fourcc.h>
#include <drm/drm_mode.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

struct nhandle { int version, numFds, numInts; int data[]; };

static double
now_ms(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

static const char *vs_src = "#version 300 es\nout vec2 uv; void main(){ vec2 p = vec2((gl_VertexID<<1)&2, gl_VertexID&2); uv = p; gl_Position = vec4(p*2.0-1.0, 0.0, 1.0); }\n";
static const char *fs_src = "#version 300 es\nprecision highp float; in vec2 uv; uniform float t; out vec4 o;\n"
	"void main(){ vec3 c = vec3(uv.x, uv.y, 0.5+0.5*sin(t*6.0)); float bar = step(abs(uv.y - t), 0.03); o = vec4(mix(c, vec3(1.0), bar), 1.0); }\n";

static GLuint
prog(void)
{
	GLuint v = glCreateShader(GL_VERTEX_SHADER), f = glCreateShader(GL_FRAGMENT_SHADER), p = glCreateProgram();

	glShaderSource(v, 1, &vs_src, NULL);
	glCompileShader(v);
	glShaderSource(f, 1, &fs_src, NULL);
	glCompileShader(f);
	glAttachShader(p, v);
	glAttachShader(p, f);
	glLinkProgram(p);
	return p;
}

int
main(int argc, char **argv)
{
	int seconds = argc > 1 ? atoi(argv[1]) : 10, i;
	AHardwareBuffer *ahb[2];
	GLuint tex[2], fbo[2];
	uint32_t fbid[2];
	AHardwareBuffer_Desc d = { .width = 1080, .height = 2424, .layers = 1, .format = AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM,
		.usage = AHARDWAREBUFFER_USAGE_GPU_COLOR_OUTPUT | AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE | AHARDWAREBUFFER_USAGE_COMPOSER_OVERLAY |
			 AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN | AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN };
	const void *(*getnh)(const AHardwareBuffer *) = dlsym(RTLD_DEFAULT, "AHardwareBuffer_getNativeHandle");
	const EGLint cattr[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE };
	const EGLint pattr[] = { EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE }, xattr[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
	EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	EGLint major, minor, n;
	EGLConfig cfg;

	setvbuf(stdout, NULL, _IONBF, 0);
	eglInitialize(dpy, &major, &minor);
	eglChooseConfig(dpy, cattr, &cfg, 1, &n);
	EGLSurface surf = eglCreatePbufferSurface(dpy, cfg, pattr);

	eglBindAPI(EGL_OPENGL_ES_API);
	EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, xattr);

	eglMakeCurrent(dpy, surf, surf, ctx);
	PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC getbuf = (PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC)eglGetProcAddress("eglGetNativeClientBufferANDROID");
	PFNEGLCREATEIMAGEKHRPROC mkimg = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
	PFNGLEGLIMAGETARGETTEXTURE2DOESPROC target = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
	const EGLint iattr[] = { EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE };

	/* the display */
	int fd = -1;
	struct drm_mode_modeinfo mode = { 0 };
	uint32_t conn = 0, crtc = 0;

	for (i = 0; i < 4 && fd < 0; i++) {
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
			if (c.connection == 1 && c.count_modes > 0 && fd < 0) {
				struct drm_mode_get_encoder e = { .encoder_id = c.encoder_id };

				ioctl(f, DRM_IOCTL_MODE_GETENCODER, &e);
				/* the 60 Hz mode first, 120 Hz if asked by HZ */
				mode = modes[0];
				for (uint32_t m = 0; m < c.count_modes; m++) {
					printf("mode %u: %ux%u@%u\n", m, modes[m].hdisplay, modes[m].vdisplay, modes[m].vrefresh);
					if (getenv("HZ") != NULL && modes[m].vrefresh == (unsigned)atoi(getenv("HZ"))) {
						mode = modes[m];
					}
				}
				conn = c.connector_id;
				crtc = e.crtc_id != 0 ? e.crtc_id : crtcs[0];
				fd = f;
			}
		}
		if (fd < 0) {
			close(f);
		}
	}
	if (fd < 0) {
		printf("no connected display\n");
		return 5;
	}
	ioctl(fd, DRM_IOCTL_SET_MASTER, 0);

	for (i = 0; i < 2; i++) {
		AHardwareBuffer_Desc got;

		if (AHardwareBuffer_allocate(&d, &ahb[i]) != 0) {
			printf("allocate %d failed\n", i);
			return 1;
		}
		AHardwareBuffer_describe(ahb[i], &got);
		const struct nhandle *nh = (const struct nhandle *)getnh(ahb[i]);
		struct drm_prime_handle ph = { .fd = nh->data[0] };

		if (ioctl(fd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &ph) < 0) {
			perror("PRIME_FD_TO_HANDLE");
			return 6;
		}
		struct drm_mode_fb_cmd2 fb = { .width = got.width, .height = got.height, .pixel_format = DRM_FORMAT_XBGR8888, .handles = { ph.handle },
			.pitches = { got.stride * 4 } };

		if (ioctl(fd, DRM_IOCTL_MODE_ADDFB2, &fb) < 0) {
			perror("ADDFB2");
			return 7;
		}
		fbid[i] = fb.fb_id;
		EGLImageKHR img = mkimg(dpy, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, getbuf(ahb[i]), iattr);

		glGenTextures(1, &tex[i]);
		glBindTexture(GL_TEXTURE_2D, tex[i]);
		target(GL_TEXTURE_2D, img);
		glGenFramebuffers(1, &fbo[i]);
		glBindFramebuffer(GL_FRAMEBUFFER, fbo[i]);
		glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex[i], 0);
		printf("buffer %d: stride %u, fb %u, status %#x\n", i, got.stride, fb.fb_id, glCheckFramebufferStatus(GL_FRAMEBUFFER));
	}
	GLuint p = prog(), vao;

	glGenVertexArrays(1, &vao);
	glBindVertexArray(vao);
	glUseProgram(p);
	GLint tloc = glGetUniformLocation(p, "t");

	/* the first picture, set with SETCRTC; then page flips */
	glBindFramebuffer(GL_FRAMEBUFFER, fbo[0]);
	glViewport(0, 0, 1080, 2424);
	glUniform1f(tloc, 0.0f);
	glDrawArrays(GL_TRIANGLES, 0, 3);
	glFinish();
	struct drm_mode_crtc sc = { .crtc_id = crtc, .fb_id = fbid[0], .set_connectors_ptr = (uintptr_t)&conn, .count_connectors = 1, .mode_valid = 1, .mode = mode };

	if (ioctl(fd, DRM_IOCTL_MODE_SETCRTC, &sc) < 0) {
		perror("SETCRTC");
		return 8;
	}
	printf("mode %ux%u@%u: the bar should move for %d s\n", mode.hdisplay, mode.vdisplay, mode.vrefresh, seconds);

	double t0 = now_ms(), last = t0, gpu_sum = 0, gpu_max = 0, int_sum = 0, int_max = 0, int_min = 1e9;
	int frames = 0, cur = 0, flip_errors = 0, pending = 0;

	while (now_ms() - t0 < seconds * 1000.0) {
		int next = cur ^ 1;
		double g0 = now_ms();

		glBindFramebuffer(GL_FRAMEBUFFER, fbo[next]);
		glUniform1f(tloc, (float)fmod((now_ms() - t0) / 3000.0, 1.0));
		glDrawArrays(GL_TRIANGLES, 0, 3);
		glFinish();
		double g1 = now_ms();

		gpu_sum += g1 - g0;
		gpu_max = g1 - g0 > gpu_max ? g1 - g0 : gpu_max;
		struct drm_mode_crtc_page_flip pf = { .crtc_id = crtc, .fb_id = fbid[next], .flags = DRM_MODE_PAGE_FLIP_EVENT, .user_data = (uint64_t)next };

		if (ioctl(fd, DRM_IOCTL_MODE_PAGE_FLIP, &pf) < 0) {
			if (flip_errors++ < 3) {
				perror("PAGE_FLIP");
			}
			if (flip_errors > 50) {
				break;
			}
			usleep(2000);
			continue;
		}
		pending = 1;
		/* wait for the flip-complete event */
		while (pending) {
			char buf[256];
			ssize_t r = read(fd, buf, sizeof buf);

			if (r <= 0) {
				break;
			}
			for (ssize_t o = 0; o < r;) {
				struct drm_event *e = (struct drm_event *)(buf + o);

				if (e->type == DRM_EVENT_FLIP_COMPLETE) {
					pending = 0;
				}
				o += e->length;
			}
		}
		double t = now_ms();

		int_sum += t - last;
		int_max = t - last > int_max ? t - last : int_max;
		int_min = t - last < int_min ? t - last : int_min;
		last = t;
		cur = next;
		frames++;
	}
	double total = now_ms() - t0;

	printf("%d flips in %.0f ms: %.1f fps; flip interval avg %.2f ms (min %.2f, max %.2f); GPU draw+finish avg %.2f ms (max %.2f); flip errors %d\n", frames,
	       total, frames * 1000.0 / total, frames ? int_sum / frames : 0, int_min, int_max, frames ? gpu_sum / frames : 0, gpu_max, flip_errors);
	return 0;
}
