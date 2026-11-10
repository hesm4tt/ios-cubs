/*
 * metal_depth: depth testing through libmtlshim.dylib in an 8x8 target with a Depth32Float texture. Both quads have z = 0 (the fixture's vertex function).
 * Pass 1, depth compare Less with depth writes: a red quad over all, then a blue quad over the right half: the blue one fails (0 < 0 is false), the right stays red.
 * Pass 2 (fresh target and depth), compare LessEqual: the blue quad passes and the right half is blue. Run by a launchd job list line "/redwood/bin/metal_depth".
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "fixture_bc.h"

extern id<MTLDevice> MTLCreateSystemDefaultDevice(void);

static void
pass(id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLRenderPipelineState> pso, MTLCompareFunction cmp, uint8_t *px)
{
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];

	td.usage = MTLTextureUsageRenderTarget;
	id<MTLTexture> target = [device newTextureWithDescriptor:td];
	MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:8 height:8 mipmapped:NO];

	dd.usage = MTLTextureUsageRenderTarget;
	id<MTLTexture> depth = [device newTextureWithDescriptor:dd];
	MTLDepthStencilDescriptor *sd = [[MTLDepthStencilDescriptor alloc] init];

	sd.depthCompareFunction = cmp;
	sd.depthWriteEnabled = YES;
	id<MTLDepthStencilState> ds = [device newDepthStencilStateWithDescriptor:sd];
	float full[8] = { -1, -1, 1, -1, -1, 1, 1, 1 };
	float right[8] = { 0, -1, 1, -1, 0, 1, 1, 1 };
	float red[16], blue[16];

	for (int i = 0; i < 4; i++) {
		red[i * 4] = 1; red[i * 4 + 1] = 0; red[i * 4 + 2] = 0; red[i * 4 + 3] = 1;
		blue[i * 4] = 0; blue[i * 4 + 1] = 0; blue[i * 4 + 2] = 1; blue[i * 4 + 3] = 1;
	}
	uint16_t idx[6] = { 0, 1, 2, 2, 1, 3 };
	id<MTLBuffer> bidx = [device newBufferWithBytes:idx length:sizeof idx options:MTLResourceStorageModeShared];
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];

	rp.colorAttachments[0].texture = target;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
	rp.depthAttachment.texture = depth;
	rp.depthAttachment.loadAction = MTLLoadActionClear;
	rp.depthAttachment.storeAction = MTLStoreActionDontCare;
	rp.depthAttachment.clearDepth = 1.0;
	id<MTLCommandBuffer> cb = [queue commandBuffer];
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];

	[enc setRenderPipelineState:pso];
	[enc setDepthStencilState:ds];
	[enc setVertexBytes:full length:sizeof full atIndex:0];
	[enc setVertexBytes:red length:sizeof red atIndex:1];
	[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:bidx indexBufferOffset:0];
	[enc setVertexBytes:right length:sizeof right atIndex:0];
	[enc setVertexBytes:blue length:sizeof blue atIndex:1];
	[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:bidx indexBufferOffset:0];
	[enc endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	[target getBytes:px bytesPerRow:8 * 4 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
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
		dispatch_data_t data = dispatch_data_create(fixture_bc, fixture_bc_len, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
		NSError *err = nil;
		id<MTLLibrary> lib = [device newLibraryWithData:data error:&err];
		MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];

		pd.vertexFunction = [lib newFunctionWithName:@"colored_vertex"];
		pd.fragmentFunction = [lib newFunctionWithName:@"colored_fragment"];
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
		pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
		id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:pd error:&err];

		if (!pso) {
			printf("metal_depth: no render pipeline\n");
			return 2;
		}
		id<MTLCommandQueue> queue = [device newCommandQueue];
		uint8_t a[8 * 8 * 4], b[8 * 8 * 4];

		pass(device, queue, pso, MTLCompareFunctionLess, a);
		pass(device, queue, pso, MTLCompareFunctionLessEqual, b);
		uint8_t *l1 = a + (1 * 8 + 1) * 4, *r1 = a + (1 * 8 + 6) * 4, *r2 = b + (1 * 8 + 6) * 4;

		printf("metal_depth: Less left %02x%02x%02x right %02x%02x%02x; LessEqual right %02x%02x%02x\n", l1[0], l1[1], l1[2], r1[0], r1[1], r1[2], r2[0], r2[1], r2[2]);
		int ok = l1[0] > 250 && r1[0] > 250 && r1[2] < 5 && r2[2] > 250 && r2[0] < 5;

		printf("metal_depth: %s\n", ok ? "DEPTH TEST AS EXPECTED" : "WRONG");
		return ok ? 0 : 3;
	}
}
