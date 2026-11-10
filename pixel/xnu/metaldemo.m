/*
 * MetalDemo.app: an ordinary UIKit application (launched by SpringBoard, own process, own window) whose view is backed by a
 * CAMetalLayer and which draws with the Metal API through libmtlshim.dylib (executed on the phone's PowerVR by mtlsrv). The
 * drawable is a little smaller than the panel (540 x 1170 pixels: the RPC carries 3 MB of pixels) and is scaled by the compositor.
 * Built by pcwork/xnu/mk_metaldemo.sh into ../apps/MetalDemo.app of the userland tree, which the system image build copies into
 * /Applications (LaunchServices finds it by walking that folder at every boot); started with `battery_test open metaldemo://`.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#include <fcntl.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>

#include "fixture_bc.h"

#define DW 540
#define DH 1170

extern id<MTLDevice> MTLCreateSystemDefaultDevice(void);

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

@interface MDView : UIView
@end

@implementation MDView
+ (Class)layerClass
{
	return [CAMetalLayer class];
}
@end

@interface MDApp : UIResponder <UIApplicationDelegate> {
	id<MTLDevice> device;
	id<MTLCommandQueue> queue;
	id<MTLRenderPipelineState> state;
	id<MTLBuffer> bpos, bcol;
	CAMetalLayer *layer;
	unsigned frame;
}
@property (nonatomic, strong) UIWindow *window;
@end

@implementation MDApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options
{
	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	UIViewController *vc = [[UIViewController alloc] init];
	MDView *view = [[MDView alloc] initWithFrame:self.window.bounds];

	vc.view = view;
	self.window.rootViewController = vc;
	[self.window makeKeyAndVisible];
	say("metaldemo: window %g x %g, layer %s\n", (double)self.window.bounds.size.width, (double)self.window.bounds.size.height,
	    object_getClassName(view.layer));
	device = MTLCreateSystemDefaultDevice();
	if (!device) {
		say("metaldemo: no Metal device from the shim\n");
		return YES;
	}
	NSError *err = nil;
	dispatch_data_t data = dispatch_data_create(fixture_bc, fixture_bc_len, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
	id<MTLLibrary> lib = [device newLibraryWithData:data error:&err];
	MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];

	pd.vertexFunction = [lib newFunctionWithName:@"colored_vertex"];
	pd.fragmentFunction = [lib newFunctionWithName:@"colored_fragment"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
	state = [device newRenderPipelineStateWithDescriptor:pd error:&err];
	if (!state) {
		say("metaldemo: no render pipeline\n");
		return YES;
	}
	queue = [device newCommandQueue];
	float col[12] = { 1, 0.7f, 0.1f, 1, 0.1f, 0.8f, 1, 1, 1, 0.2f, 0.6f, 1 };

	bcol = [device newBufferWithBytes:col length:sizeof col options:MTLResourceStorageModeShared];
	bpos = [device newBufferWithLength:sizeof(float) * 6 options:MTLResourceStorageModeShared];
	layer = (CAMetalLayer *)view.layer;
	layer.device = device;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	layer.framebufferOnly = NO;
	layer.drawableSize = CGSizeMake(DW, DH);
	say("metaldemo: Metal device ready, drawing\n");
	[NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
	return YES;
}

- (void)tick
{
	float a = (float)frame * 0.1f, *pos = [bpos contents];
	float ratio = (float)DW / (float)DH;

	for (int i = 0; i < 3; i++) {
		float t = a + (float)i * 2.0944f;

		pos[i * 2] = 0.9f * cosf(t);
		pos[i * 2 + 1] = 0.9f * sinf(t) / ratio * 0.6f;
	}
	id<CAMetalDrawable> drawable = [layer nextDrawable];

	if (!drawable) {
		say("metaldemo: nextDrawable gave nil\n");
		return;
	}
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];

	rp.colorAttachments[0].texture = drawable.texture;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.1 + 0.05 * sin(a), 0.25, 1);
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
	if (frame++ % 50 == 0) {
		say("metaldemo: frame %u\n", frame - 1);
	}
}
@end

int
main(int argc, char **argv)
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, @"MDApp");
	}
}
