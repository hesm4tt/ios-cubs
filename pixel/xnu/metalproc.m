/*
 * metalproc: a separate iOS process (a launchd job line "/redwood/bin/metalproc &") that draws with the Metal API through
 * libmtlshim.dylib (the PowerVR on the phone, see mtlsrv) into a CAMetalLayer of a CoreAnimation context of its own
 * (+[CAContext remoteContextWithOptions:]). It writes the context's id to /var/tmp/metalproc.ctx; SpringBoard (libmtlhost.dylib)
 * shows that context with a CALayerHost. Metal output of another process inside iOS's compositor.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <fcntl.h>
#include <math.h>
#include <objc/message.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#include "fixture_bc.h"

#define SIZE 256
#define SCALE 3

static void
say(const char *format, ...)
{
	char line[300];
	va_list ap;
	int con = open("/dev/console", O_WRONLY);

	va_start(ap, format);
	int n = vsnprintf(line, sizeof line, format, ap);
	va_end(ap);
	if (con >= 0) {
		if (n > 0) {
			(void)write(con, line, (size_t)(n < (int)sizeof line ? n : (int)sizeof line - 1));
		}
		close(con);
	}
}

static CAMetalLayer *ml;
static id<MTLDevice> gdevice;

static void *
render_thread(void *arg)
{
	(void)arg;
	@autoreleasepool {
		NSError *err = nil;
		dispatch_data_t data = dispatch_data_create(fixture_bc, fixture_bc_len, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
		id<MTLLibrary> lib = [gdevice newLibraryWithData:data error:&err];
		MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];

		pd.vertexFunction = [lib newFunctionWithName:@"colored_vertex"];
		pd.fragmentFunction = [lib newFunctionWithName:@"colored_fragment"];
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
		id<MTLRenderPipelineState> state = [gdevice newRenderPipelineStateWithDescriptor:pd error:&err];

		if (!state) {
			say("metalproc: no render pipeline\n");
			return NULL;
		}
		id<MTLCommandQueue> queue = [gdevice newCommandQueue];
		float col[12] = { 0.1f, 1, 0.2f, 1, 0.1f, 1, 0.2f, 1, 0.2f, 1, 0.3f, 1 };
		id<MTLBuffer> bcol = [gdevice newBufferWithBytes:col length:sizeof col options:MTLResourceStorageModeShared];

		say("metalproc: Metal device ready, rendering\n");
		for (unsigned frame = 0;; frame++) {
			float a = -(float)frame * 0.15f, pos[6];

			for (int i = 0; i < 3; i++) {
				float t = a + (float)i * 2.0944f;

				pos[i * 2] = 0.8f * cosf(t);
				pos[i * 2 + 1] = 0.8f * sinf(t);
			}
			id<MTLBuffer> bpos = [gdevice newBufferWithBytes:pos length:sizeof pos options:MTLResourceStorageModeShared];
			id<CAMetalDrawable> drawable = [ml nextDrawable];

			if (!drawable) {
				sleep(1);
				continue;
			}
			MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];

			rp.colorAttachments[0].texture = drawable.texture;
			rp.colorAttachments[0].loadAction = MTLLoadActionClear;
			rp.colorAttachments[0].storeAction = MTLStoreActionStore;
			rp.colorAttachments[0].clearColor = MTLClearColorMake(0.2, 0.05, 0.05, 1);
			id<MTLCommandBuffer> cb = [queue commandBuffer];
			id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];

			[enc setRenderPipelineState:state];
			[enc setVertexBuffer:bpos offset:0 atIndex:0];
			[enc setVertexBuffer:bcol offset:0 atIndex:1];
			[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
			[enc endEncoding];
			[cb presentDrawable:drawable];
			[cb commit];
			[cb waitUntilCompleted];
			if (frame % 50 == 0) {
				say("metalproc: frame %u\n", frame);
			}
			usleep(100000);
		}
	}
	return NULL;
}

int
main(void)
{
	@autoreleasepool {
		setvbuf(stdout, NULL, _IOLBF, 0);
		id<MTLDevice> (*create)(void) = MTLCreateSystemDefaultDevice;

		for (int tries = 0; !gdevice && tries < 100; tries++) {
			gdevice = create();
			if (!gdevice) {
				sleep(3);
			}
		}
		if (!gdevice) {
			say("metalproc: no Metal device from the shim\n");
			return 1;
		}
		Class contextClass = NSClassFromString(@"CAContext");

		if (!contextClass) {
			say("metalproc: no CAContext\n");
			return 2;
		}
		id context = ((id (*)(id, SEL, id))objc_msgSend)(contextClass, sel_registerName("remoteContextWithOptions:"), @{});

		if (!context) {
			say("metalproc: remoteContextWithOptions: gave nil\n");
			return 3;
		}
		CALayer *root = [CALayer layer];

		root.bounds = CGRectMake(0, 0, SIZE, SIZE);
		root.anchorPoint = CGPointZero;
		root.position = CGPointZero;
		ml = [CAMetalLayer layer];
		ml.device = gdevice;
		ml.pixelFormat = MTLPixelFormatBGRA8Unorm;
		ml.framebufferOnly = NO;
		root.contentsScale = SCALE;
		ml.contentsScale = SCALE;
		ml.drawableSize = CGSizeMake(SIZE * SCALE / 2, SIZE * SCALE / 2);
		ml.frame = CGRectMake(0, 0, SIZE, SIZE);
		[root addSublayer:ml];
		((void (*)(id, SEL, id))objc_msgSend)(context, sel_registerName("setLayer:"), root);
		unsigned cid = ((unsigned (*)(id, SEL))objc_msgSend)(context, sel_registerName("contextId"));
		FILE *f = fopen("/var/tmp/metalproc.ctx", "w");

		if (f) {
			fprintf(f, "%u\n", cid);
			fclose(f);
			chmod("/var/tmp/metalproc.ctx", 0666);
		}
		say("metalproc: CAContext id %u, layer tree ready\n", cid);
		pthread_t t;

		pthread_create(&t, NULL, render_thread, NULL);
		pthread_detach(t);
		CFRunLoopRun();
	}
	return 0;
}
