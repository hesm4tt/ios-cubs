/*
 * metal_deflib: the library entry points an app uses: newDefaultLibrary (default.metallib next to the executable), newLibraryWithFile:, newLibraryWithURL:;
 * each library makes a render pipeline from the fixture's colored_vertex / colored_fragment. Run by a launchd job list line "/redwood/bin/metal_deflib".
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <unistd.h>

extern id<MTLDevice> MTLCreateSystemDefaultDevice(void);

static int
pipeline(id<MTLDevice> device, id<MTLLibrary> lib)
{
	if (!lib) {
		return 0;
	}
	MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
	NSError *err = nil;

	pd.vertexFunction = [lib newFunctionWithName:@"colored_vertex"];
	pd.fragmentFunction = [lib newFunctionWithName:@"colored_fragment"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
	return [device newRenderPipelineStateWithDescriptor:pd error:&err] != nil;
}

int
main(void)
{
	@autoreleasepool {
		setvbuf(stdout, NULL, _IOLBF, 0);
		id<MTLDevice> device = nil;

		for (int tries = 0; !device && tries < 200; tries++) {
			device = MTLCreateSystemDefaultDevice();
			if (!device) {
				sleep(2);
			}
		}
		if (!device) {
			return 1;
		}
		NSError *err = nil;
		int a = pipeline(device, [device newDefaultLibrary]);
		int b = pipeline(device, [device newLibraryWithFile:@"/redwood/bin/default.metallib" error:&err]);
		int c = pipeline(device, [device newLibraryWithURL:[NSURL fileURLWithPath:@"/redwood/bin/default.metallib"] error:&err]);

		printf("metal_deflib: default library %s, file %s, url %s\n", a ? "ok" : "FAILED", b ? "ok" : "FAILED", c ? "ok" : "FAILED");
		printf("metal_deflib: %s\n", a && b && c ? "LIBRARY ENTRY POINTS AS EXPECTED" : "WRONG");
		return a && b && c ? 0 : 3;
	}
}
