/*
 * libmtloverlay.dylib: injected into SpringBoard (INJECT line "/redwood/bin/libmtloverlay.dylib SpringBoard"). A thread renders a
 * spinning triangle with the Metal API through libmtlshim.dylib (the shim sends it to the metal2vulkan runtime on the phone's
 * PowerVR GPU, see mtlsrv), reads the texture back and puts it into a CALayer added to SpringBoard's window: CoreAnimation's
 * render server draws that layer like any other, with the OpenGL ES forwarded to the same GPU (gl_fwd.c).
 * Metal output inside iOS's own compositor.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>

#include "fixture_bc.h"

#define SIZE 256

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

static CALayer *layer;
static id<MTLDevice> gdevice;

static void
attach_layer(void)
{
	UIApplication *app = [UIApplication sharedApplication];
	UIWindow *best = nil;

	for (UIWindow *w in [app windows]) {
		say("mtloverlay: window %s level %g hidden %d frame %g x %g\n", object_getClassName(w), (double)w.windowLevel, (int)w.hidden,
		    (double)w.bounds.size.width, (double)w.bounds.size.height);
		if (!w.hidden && w.bounds.size.width > 300 && (!best || w.windowLevel >= best.windowLevel)) {
			best = w;
		}
	}
	if (!best) {
		say("mtloverlay: no window yet\n");
		return;
	}
	CAMetalLayer *ml = [CAMetalLayer layer];

	ml.device = gdevice;
	ml.pixelFormat = MTLPixelFormatBGRA8Unorm;
	ml.framebufferOnly = NO;
	ml.drawableSize = CGSizeMake(SIZE, SIZE);
	layer = ml;
	layer.frame = CGRectMake(40, 520, SIZE, SIZE);
	layer.cornerRadius = 24;
	layer.masksToBounds = YES;
	layer.borderWidth = 3;
	layer.borderColor = [UIColor whiteColor].CGColor;
	layer.zPosition = 1000000;
	[best.layer addSublayer:layer];
	say("mtloverlay: layer added to a %s\n", object_getClassName(best));
}

static void
show(const uint8_t *px)
{
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CFDataRef data = CFDataCreate(NULL, px, SIZE * SIZE * 4);
	CGDataProviderRef dp = CGDataProviderCreateWithCFData(data);
	CGImageRef img = CGImageCreate(SIZE, SIZE, 8, 32, SIZE * 4, cs, kCGBitmapByteOrderDefault | kCGImageAlphaPremultipliedLast, dp, NULL, false,
	    kCGRenderingIntentDefault);

	dispatch_async(dispatch_get_main_queue(), ^{
		if (!layer) {
			attach_layer();
		}
		if (layer) {
			[CATransaction begin];
			[CATransaction setDisableActions:YES];
			layer.contents = (__bridge id)img;
			[CATransaction commit];
		}
		CGImageRelease(img);
	});
	CGDataProviderRelease(dp);
	CFRelease(data);
	CGColorSpaceRelease(cs);
}

static void *
render_thread(void *arg)
{
	(void)arg;
	@autoreleasepool {
		sleep(60);
		void *shim = dlopen("/redwood/bin/libmtlshim.dylib", RTLD_NOW | RTLD_GLOBAL);

		if (!shim) {
			say("mtloverlay: %s\n", dlerror());
			return NULL;
		}
		id<MTLDevice> (*create)(void) = (id<MTLDevice> (*)(void))dlsym(shim, "MTLCreateSystemDefaultDevice");
		id<MTLDevice> device = create ? create() : nil;

		for (int tries = 0; !device && tries < 100; tries++) {
			sleep(3);
			device = create ? create() : nil;
		}
		if (!device) {
			say("mtloverlay: no Metal device from the shim\n");
			return NULL;
		}
		gdevice = device;
		dispatch_async(dispatch_get_main_queue(), ^{ attach_layer(); });
		for (int i = 0; i < 100 && !layer; i++) {
			sleep(2);
			dispatch_async(dispatch_get_main_queue(), ^{ if (!layer) { attach_layer(); } });
		}
		NSError *err = nil;
		dispatch_data_t data = dispatch_data_create(fixture_bc, fixture_bc_len, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
		id<MTLLibrary> lib = [device newLibraryWithData:data error:&err];
		MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];

		pd.vertexFunction = [lib newFunctionWithName:@"colored_vertex"];
		pd.fragmentFunction = [lib newFunctionWithName:@"colored_fragment"];
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
		id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:pd error:&err];

		if (!state) {
			say("mtloverlay: no render pipeline\n");
			return NULL;
		}
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:SIZE height:SIZE
											    mipmapped:NO];

		td.usage = MTLTextureUsageRenderTarget;
		id<MTLCommandQueue> queue = [device newCommandQueue];
		float col[12] = { 1, 0.1f, 0.1f, 1, 0.1f, 1, 0.1f, 1, 0.2f, 0.4f, 1, 1 };
		id<MTLBuffer> bcol = [device newBufferWithBytes:col length:sizeof col options:MTLResourceStorageModeShared];
		static uint8_t px[SIZE * SIZE * 4];
		unsigned frame = 0;

		say("mtloverlay: Metal device ready, rendering\n");
		for (;; frame++) {
			float a = (float)frame * 0.12f;
			float pos[6];

			for (int i = 0; i < 3; i++) {
				float t = a + (float)i * 2.0944f;

				pos[i * 2] = 0.8f * cosf(t);
				pos[i * 2 + 1] = 0.8f * sinf(t);
			}
			id<MTLBuffer> bpos = [device newBufferWithBytes:pos length:sizeof pos options:MTLResourceStorageModeShared];
			MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];

			id<CAMetalDrawable> drawable = [(CAMetalLayer *)layer nextDrawable];

			if (!drawable) {
				say("mtloverlay: nextDrawable gave nil\n");
				sleep(1);
				continue;
			}
			rp.colorAttachments[0].texture = drawable.texture;
			rp.colorAttachments[0].loadAction = MTLLoadActionClear;
			rp.colorAttachments[0].storeAction = MTLStoreActionStore;
			rp.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.2, 1);
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
				say("mtloverlay: frame %u\n", frame);
			}
			usleep(100000);
		}
	}
	return NULL;
}

__attribute__((constructor)) static void
start(void)
{
	pthread_t t;

	if (pthread_create(&t, NULL, render_thread, NULL) == 0) {
		pthread_detach(t);
	}
}
