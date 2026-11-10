/*
 * metal_inst: instanced and indirect draws through libmtlshim.dylib. A half-transparent blue quad (SourceAlpha / OneMinusSourceAlpha) over black: one instance
 * gives blue 128, two 192, three 224 (each instance draws on top of the last; the fixture's vertex function ignores the instance id). Checks: a direct draw
 * with instanceCount 3, an indexed draw with instanceCount 2, and an indexed indirect draw whose buffer says 3 instances.
 * Run by a launchd job list line "/redwood/bin/metal_inst".
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "fixture_bc.h"

extern id<MTLDevice> MTLCreateSystemDefaultDevice(void);

static id<MTLDevice> g_device;
static id<MTLCommandQueue> g_queue;
static id<MTLRenderPipelineState> g_pso;
static id<MTLBuffer> g_idx;
static float g_quad[8] = { -1, -1, 1, -1, -1, 1, 1, 1 };
static float g_col[16];

typedef void (^Draw)(id<MTLRenderCommandEncoder>);

static int
run(Draw draw)
{
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];

	td.usage = MTLTextureUsageRenderTarget;
	id<MTLTexture> target = [g_device newTextureWithDescriptor:td];
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];

	rp.colorAttachments[0].texture = target;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
	id<MTLCommandBuffer> cb = [g_queue commandBuffer];
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];

	[enc setRenderPipelineState:g_pso];
	[enc setVertexBytes:g_quad length:sizeof g_quad atIndex:0];
	[enc setVertexBytes:g_col length:sizeof g_col atIndex:1];
	draw(enc);
	[enc endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	uint8_t px[4];

	[target getBytes:px bytesPerRow:4 fromRegion:MTLRegionMake2D(3, 3, 1, 1) mipmapLevel:0];
	return px[2];
}

int
main(void)
{
	@autoreleasepool {
		setvbuf(stdout, NULL, _IOLBF, 0);
		for (int tries = 0; !g_device && tries < 200; tries++) {
			g_device = MTLCreateSystemDefaultDevice();
			if (!g_device) {
				sleep(2);
			}
		}
		if (!g_device) {
			return 1;
		}
		dispatch_data_t data = dispatch_data_create(fixture_bc, fixture_bc_len, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
		NSError *err = nil;
		id<MTLLibrary> lib = [g_device newLibraryWithData:data error:&err];
		MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];

		pd.vertexFunction = [lib newFunctionWithName:@"colored_vertex"];
		pd.fragmentFunction = [lib newFunctionWithName:@"colored_fragment"];
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
		pd.colorAttachments[0].blendingEnabled = YES;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		g_pso = [g_device newRenderPipelineStateWithDescriptor:pd error:&err];

		if (!g_pso) {
			printf("metal_inst: no render pipeline\n");
			return 2;
		}
		for (int i = 0; i < 4; i++) {
			g_col[i * 4] = 0; g_col[i * 4 + 1] = 0; g_col[i * 4 + 2] = 1; g_col[i * 4 + 3] = 0.5f;
		}
		g_queue = [g_device newCommandQueue];
		uint16_t idx[6] = { 0, 1, 2, 2, 1, 3 };

		g_idx = [g_device newBufferWithBytes:idx length:sizeof idx options:MTLResourceStorageModeShared];
		uint32_t args[5] = { 6, 3, 0, 0, 0 };
		id<MTLBuffer> ind = [g_device newBufferWithBytes:args length:sizeof args options:MTLResourceStorageModeShared];
		/* the quad as a triangle strip of four vertices for the direct draw */
		int a = run(^(id<MTLRenderCommandEncoder> e) {
			[e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:3];
		});
		int b = run(^(id<MTLRenderCommandEncoder> e) {
			[e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:g_idx indexBufferOffset:0 instanceCount:2];
		});
		int c = run(^(id<MTLRenderCommandEncoder> e) {
			[e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexType:MTLIndexTypeUInt16 indexBuffer:g_idx indexBufferOffset:0 indirectBuffer:ind
			    indirectBufferOffset:0];
		});

		printf("metal_inst: direct x3 blue %d, indexed x2 blue %d, indirect x3 blue %d\n", a, b, c);
		int ok = a > 215 && a < 232 && b > 183 && b < 200 && c > 215 && c < 232;

		printf("metal_inst: %s\n", ok ? "INSTANCED AND INDIRECT DRAWS AS EXPECTED" : "WRONG");
		return ok ? 0 : 3;
	}
}
