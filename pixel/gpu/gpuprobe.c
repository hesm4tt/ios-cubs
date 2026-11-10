/*
 * gpuprobe: spike for zero-copy presentation (plan "make iOS rendering fast", Phase 1). Runs on Android as root (NDK).
 *   gpuprobe ext         print what the phone's GL/EGL (ANGLE on the PowerVR) and Vulkan offer for sharing buffers: dma-buf import/export,
 *                        AHardwareBuffer, image modifiers. No display change.
 *   gpuprobe scan [sec]  Spike A: allocate an AHardwareBuffer (scanout usage), draw four colour bands into it with GLES through an EGLImage,
 *                        export its dma-buf, wrap it in a DRM framebuffer (PRIME_FD_TO_HANDLE + ADDFB2) and put it on the panel with SETCRTC for
 *                        `sec` seconds (default 8). Needs "stop surfaceflinger; stop vendor.hwcomposer-3" first (DRM master); restore with
 *                        "start vendor.hwcomposer-3; start surfaceflinger" afterwards (gpuprobe_scan.sh does both).
 * Built with the NDK: $T/bin/aarch64-linux-android31-clang -O2 -o gpuprobe gpuprobe.c -lEGL -lGLESv3 -lnativewindow -lvulkan -ldl
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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

struct nhandle { int version, numFds, numInts; int data[]; };

static void
words(const char *what, const char *list, const char *const *wanted)
{
	printf("%s:\n", what);
	for (int i = 0; wanted[i] != NULL; i++) {
		const char *p = list != NULL ? strstr(list, wanted[i]) : NULL;

		printf("  %-48s %s\n", wanted[i], p != NULL ? "yes" : "no");
	}
}

static void
print_ext(void)
{
	static const char *const egl_w[] = { "EGL_ANDROID_image_native_buffer", "EGL_ANDROID_get_native_client_buffer", "EGL_EXT_image_dma_buf_import",
		"EGL_EXT_image_dma_buf_import_modifiers", "EGL_KHR_image_base", "EGL_KHR_gl_texture_2D_image", "EGL_ANDROID_native_fence_sync",
		"EGL_KHR_fence_sync", "EGL_KHR_surfaceless_context", "EGL_MESA_image_dma_buf_export", "EGL_ANDROID_front_buffer_auto_refresh", NULL };
	static const char *const gl_w[] = { "GL_OES_EGL_image", "GL_OES_EGL_image_external", "GL_EXT_buffer_storage", "GL_EXT_memory_object",
		"GL_EXT_memory_object_fd", "GL_EXT_semaphore", "GL_EXT_semaphore_fd", "GL_ANGLE_texture_storage_external", NULL };
	static const char *const vk_w[] = { "VK_EXT_external_memory_dma_buf", "VK_KHR_external_memory_fd", "VK_ANDROID_external_memory_android_hardware_buffer",
		"VK_EXT_image_drm_format_modifier", "VK_KHR_external_semaphore_fd", "VK_KHR_timeline_semaphore", "VK_KHR_dynamic_rendering",
		"VK_EXT_queue_family_foreign", "VK_KHR_external_fence_fd", "VK_EXT_external_memory_host", "VK_KHR_swapchain", NULL };
	const EGLint cattr[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE };
	const EGLint pattr[] = { EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE }, xattr[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
	EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	EGLint major, minor, n;
	EGLConfig cfg;

	if (!eglInitialize(dpy, &major, &minor)) {
		printf("eglInitialize failed %x\n", eglGetError());
		return;
	}
	printf("EGL %d.%d vendor %s, version %s\n", major, minor, eglQueryString(dpy, EGL_VENDOR), eglQueryString(dpy, EGL_VERSION));
	words("EGL extensions", eglQueryString(dpy, EGL_EXTENSIONS), egl_w);
	eglChooseConfig(dpy, cattr, &cfg, 1, &n);
	EGLSurface surf = eglCreatePbufferSurface(dpy, cfg, pattr);
	EGLContext ctx;

	eglBindAPI(EGL_OPENGL_ES_API);
	ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, xattr);
	eglMakeCurrent(dpy, surf, surf, ctx);
	printf("GL vendor %s, renderer %s, version %s\n", glGetString(GL_VENDOR), glGetString(GL_RENDERER), glGetString(GL_VERSION));
	words("GL extensions", (const char *)glGetString(GL_EXTENSIONS), gl_w);

	/* Vulkan: the device and the extensions for sharing memory */
	VkApplicationInfo ai = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_1 };
	VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &ai };
	VkInstance inst;
	uint32_t nd = 0;

	if (vkCreateInstance(&ici, NULL, &inst) != VK_SUCCESS) {
		printf("vkCreateInstance failed\n");
		return;
	}
	vkEnumeratePhysicalDevices(inst, &nd, NULL);
	VkPhysicalDevice devs[4];

	nd = nd > 4 ? 4 : nd;
	vkEnumeratePhysicalDevices(inst, &nd, devs);
	for (uint32_t d = 0; d < nd; d++) {
		VkPhysicalDeviceProperties pr;
		uint32_t ne = 0;

		vkGetPhysicalDeviceProperties(devs[d], &pr);
		printf("Vulkan device %u: %s, API %u.%u.%u, driver %#x\n", d, pr.deviceName, VK_VERSION_MAJOR(pr.apiVersion), VK_VERSION_MINOR(pr.apiVersion),
		       VK_VERSION_PATCH(pr.apiVersion), pr.driverVersion);
		vkEnumerateDeviceExtensionProperties(devs[d], NULL, &ne, NULL);
		VkExtensionProperties *ex = calloc(ne, sizeof *ex);
		char *all = calloc(ne + 1, 64);

		vkEnumerateDeviceExtensionProperties(devs[d], NULL, &ne, ex);
		for (uint32_t i = 0; i < ne; i++) {
			strcat(all, ex[i].extensionName);
			strcat(all, " ");
		}
		words("Vulkan device extensions", all, vk_w);
		printf("  (%u extensions in all)\n", ne);
		free(all);
		free(ex);
	}
}

static uint32_t
band_colour(int b, float *c)
{
	static const float t[4][4] = { { 1, 0, 0, 1 }, { 0, 1, 0, 1 }, { 0, 0, 1, 1 }, { 1, 1, 0, 1 } };

	memcpy(c, t[b & 3], sizeof t[0]);
	return 0;
}

static int
scan(int seconds)
{
	AHardwareBuffer *ahb = NULL;
	AHardwareBuffer_Desc d = { .width = 1080, .height = 2424, .layers = 1, .format = AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM,
		.usage = AHARDWAREBUFFER_USAGE_GPU_COLOR_OUTPUT | AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE | AHARDWAREBUFFER_USAGE_COMPOSER_OVERLAY };
	if (getenv("LIN") != NULL) {
		/* CPU usage makes gralloc pick a linear layout (the GPU's own tiled/compressed layouts cannot be scanned out without a DRM modifier) */
		d.usage |= AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN | AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN;
	}
	int r = AHardwareBuffer_allocate(&d, &ahb);

	printf("AHardwareBuffer_allocate: %d\n", r);
	if (r != 0) {
		/* without the overlay usage: perhaps not scanout capable, but let us see what happens */
		d.usage &= ~AHARDWAREBUFFER_USAGE_COMPOSER_OVERLAY;
		r = AHardwareBuffer_allocate(&d, &ahb);
		printf("... without COMPOSER_OVERLAY: %d\n", r);
		if (r != 0) {
			return 1;
		}
	}
	AHardwareBuffer_Desc got;

	AHardwareBuffer_describe(ahb, &got);
	printf("buffer %ux%u stride %u (pixels) format %u usage %#llx\n", got.width, got.height, got.stride, got.format, (unsigned long long)got.usage);
	/* not in the NDK headers: the VNDK function of libnativewindow */
	const void *(*getnh)(const AHardwareBuffer *) = dlsym(RTLD_DEFAULT, "AHardwareBuffer_getNativeHandle");
	const struct nhandle *nh = getnh != NULL ? (const struct nhandle *)getnh(ahb) : NULL;

	printf("AHardwareBuffer_getNativeHandle: %p\n", (void *)getnh);

	printf("native handle: %d fds, %d ints; fd0 %d\n", nh != NULL ? nh->numFds : -1, nh != NULL ? nh->numInts : -1, nh != NULL && nh->numFds > 0 ? nh->data[0] : -1);

	/* draw into it with GLES via an EGLImage */
	const EGLint cattr[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE };
	const EGLint pattr[] = { EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE }, xattr[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
	EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	EGLint major, minor, n;
	EGLConfig cfg;

	eglInitialize(dpy, &major, &minor);
	eglChooseConfig(dpy, cattr, &cfg, 1, &n);
	EGLSurface surf = eglCreatePbufferSurface(dpy, cfg, pattr);

	eglBindAPI(EGL_OPENGL_ES_API);
	EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, xattr);

	eglMakeCurrent(dpy, surf, surf, ctx);
	PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC getbuf = (PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC)eglGetProcAddress("eglGetNativeClientBufferANDROID");
	PFNEGLCREATEIMAGEKHRPROC mkimg = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
	PFNGLEGLIMAGETARGETTEXTURE2DOESPROC target = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");

	if (getbuf == NULL || mkimg == NULL || target == NULL) {
		printf("missing EGL/GL functions: getbuf %p mkimg %p target %p\n", (void *)getbuf, (void *)mkimg, (void *)target);
		return 2;
	}
	const EGLint iattr[] = { EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE };
	EGLImageKHR img = mkimg(dpy, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, getbuf(ahb), iattr);

	printf("eglCreateImageKHR: %p (egl error %#x)\n", img, eglGetError());
	if (img == EGL_NO_IMAGE_KHR) {
		return 3;
	}
	GLuint tex, fbo;

	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	target(GL_TEXTURE_2D, img);
	glGenFramebuffers(1, &fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
	printf("framebuffer status %#x\n", glCheckFramebufferStatus(GL_FRAMEBUFFER));
	glEnable(GL_SCISSOR_TEST);
	for (int b = 0; b < 4; b++) {
		float c[4];

		band_colour(b, c);
		glScissor(0, b * (int)got.height / 4, (int)got.width, (int)got.height / 4);
		glClearColor(c[0], c[1], c[2], c[3]);
		glClear(GL_COLOR_BUFFER_BIT);
	}
	glDisable(GL_SCISSOR_TEST);
	glFinish();
	printf("drawn with GLES (error %#x)\n", glGetError());
	if (nh == NULL || nh->numFds < 1) {
		return 4;
	}

	/* DRM: wrap the dma-buf and put it on the panel */
	int fd = -1, i;
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
		printf("%s: %u crtcs, %u connectors\n", path, res.count_crtcs, res.count_connectors);
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
			printf("  connector %u: connection %u, %u modes, encoder %u\n", c.connector_id, c.connection, c.count_modes, c.encoder_id);
			if (c.connection == 1 && c.count_modes > 0 && fd < 0) {
				struct drm_mode_get_encoder e = { .encoder_id = c.encoder_id };

				ioctl(f, DRM_IOCTL_MODE_GETENCODER, &e);
				mode = modes[0];
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
	printf("using mode %ux%u@%u crtc %u connector %u\n", mode.hdisplay, mode.vdisplay, mode.vrefresh, crtc, conn);
	if (ioctl(fd, DRM_IOCTL_SET_MASTER, 0) < 0) {
		perror("SET_MASTER (is surfaceflinger stopped?)");
	}
	struct drm_prime_handle ph = { .fd = nh->data[0], .flags = 0 };

	if (ioctl(fd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &ph) < 0) {
		perror("PRIME_FD_TO_HANDLE");
		return 6;
	}
	printf("GEM handle %u\n", ph.handle);
	struct drm_mode_fb_cmd2 fb = { .width = got.width, .height = got.height, .pixel_format = DRM_FORMAT_XBGR8888, .handles = { ph.handle },
		.pitches = { got.stride * 4 }, .offsets = { 0 } };

	if (ioctl(fd, DRM_IOCTL_MODE_ADDFB2, &fb) < 0) {
		perror("ADDFB2 (XBGR8888)");
		fb.pixel_format = DRM_FORMAT_ABGR8888;
		if (ioctl(fd, DRM_IOCTL_MODE_ADDFB2, &fb) < 0) {
			perror("ADDFB2 (ABGR8888)");
			return 7;
		}
	}
	printf("DRM framebuffer %u\n", fb.fb_id);
	struct drm_mode_crtc sc = { .crtc_id = crtc, .fb_id = fb.fb_id, .set_connectors_ptr = (uintptr_t)&conn, .count_connectors = 1, .mode_valid = 1, .mode = mode };

	if (ioctl(fd, DRM_IOCTL_MODE_SETCRTC, &sc) < 0) {
		perror("SETCRTC");
		return 8;
	}
	printf("on the panel: four colour bands (red, green, blue, yellow from the top if the rows are bottom-up the order is reversed) for %d s\n", seconds);
	sleep((unsigned)seconds);
	return 0;
}

int
main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	if (argc > 1 && strcmp(argv[1], "ext") == 0) {
		print_ext();
		return 0;
	}
	if (argc > 1 && strcmp(argv[1], "scan") == 0) {
		return scan(argc > 2 ? atoi(argv[2]) : 8);
	}
	printf("usage: gpuprobe ext | scan [seconds]\n");
	return 2;
}
