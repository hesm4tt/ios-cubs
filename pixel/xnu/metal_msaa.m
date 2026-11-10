/*
 * metal_msaa: 4x multisampling through libmtlshim.dylib. A 8x8 RGBA8 2DMultisample target (sampleCount 4) and an 8x8 resolve texture; a red triangle whose
 * diagonal edge runs through the target is drawn with a pipeline of sampleCount 4 and a pass that resolves (MTLStoreActionMultisampleResolve). In the resolved
 * image, texels well inside the triangle are full red, texels well outside are black, and some texels on the diagonal are partly covered (neither).
 * Run by a launchd job list line "/redwood/bin/metal_msaa".
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "fixture_bc.h"

extern id<MTLDevice> MTLCreateSystemDefaultDevice(void);

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
		dispatch_data_t data = dispatch_data_create(fixture_bc, fixture_bc_len, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
		NSError *err = nil;
		id<MTLLibrary> lib = [device newLibraryWithData:data error:&err];
		MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];

		pd.vertexFunction = [lib newFunctionWithName:@"colored_vertex"];
		pd.fragmentFunction = [lib newFunctionWithName:@"colored_fragment"];
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
		pd.sampleCount = 4;
		id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:pd error:&err];

		if (!pso) {
			printf("metal_msaa: no render pipeline\n");
			return 2;
		}
		MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];

		md.textureType = MTLTextureType2DMultisample;
		md.sampleCount = 4;
		md.usage = MTLTextureUsageRenderTarget;
		id<MTLTexture> ms = [device newTextureWithDescriptor:md];
		MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];

		rd.usage = MTLTextureUsageRenderTarget;
		id<MTLTexture> resolve = [device newTextureWithDescriptor:rd];
		float tri[6] = { -1, -1, 1, -1, -1, 1 };
		float red[12];

		for (int i = 0; i < 3; i++) {
			red[i * 4] = 1; red[i * 4 + 1] = 0; red[i * 4 + 2] = 0; red[i * 4 + 3] = 1;
		}
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];

		rp.colorAttachments[0].texture = ms;
		rp.colorAttachments[0].resolveTexture = resolve;
		rp.colorAttachments[0].loadAction = MTLLoadActionClear;
		rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
		rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
		id<MTLCommandQueue> queue = [device newCommandQueue];
		id<MTLCommandBuffer> cb = [queue commandBuffer];
		id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];

		[enc setRenderPipelineState:pso];
		[enc setVertexBytes:tri length:sizeof tri atIndex:0];
		[enc setVertexBytes:red length:sizeof red atIndex:1];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[enc endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		uint8_t px[8 * 8 * 4];

		[resolve getBytes:px bytesPerRow:8 * 4 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
		int inside = 0, outside = 0, partial = 0;

		for (int y = 0; y < 8; y++) {
			for (int x = 0; x < 8; x++) {
				uint8_t r = px[(y * 8 + x) * 4];

				/* the triangle covers the lower-left half in clip space; in texels (y down) the covered side is x + y < 7.. */
				if (r == 255) {
					inside++;
				} else if (r == 0) {
					outside++;
				} else {
					partial++;
				}
			}
		}
		printf("metal_msaa: samples %lu type %lu; full %d empty %d partial %d\n", (unsigned long)[ms sampleCount], (unsigned long)[ms textureType], inside, outside, partial);
		int ok = inside > 10 && outside > 10 && partial > 0;

		printf("metal_msaa: %s\n", ok ? "MSAA RESOLVE AS EXPECTED" : "WRONG");
		return ok ? 0 : 3;
	}
}
