/*
 * metal_msaadepth: 4x multisampling together with a Depth32Float multisample attachment. A full red quad, then a full blue quad at the same depth with depth
 * compare Less and depth writes: the blue one fails everywhere, the resolved 8x8 image is all red. A second pass with LessEqual draws blue everywhere.
 * Run by a launchd job list line "/redwood/bin/metal_msaadepth".
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
	MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];

	md.textureType = MTLTextureType2DMultisample;
	md.sampleCount = 4;
	md.usage = MTLTextureUsageRenderTarget;
	id<MTLTexture> ms = [device newTextureWithDescriptor:md];
	MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:8 height:8 mipmapped:NO];

	dd.textureType = MTLTextureType2DMultisample;
	dd.sampleCount = 4;
	dd.usage = MTLTextureUsageRenderTarget;
	id<MTLTexture> depth = [device newTextureWithDescriptor:dd];
	MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];

	rd.usage = MTLTextureUsageRenderTarget;
	id<MTLTexture> resolve = [device newTextureWithDescriptor:rd];
	MTLDepthStencilDescriptor *sd = [[MTLDepthStencilDescriptor alloc] init];

	sd.depthCompareFunction = cmp;
	sd.depthWriteEnabled = YES;
	id<MTLDepthStencilState> ds = [device newDepthStencilStateWithDescriptor:sd];
	float full[8] = { -1, -1, 1, -1, -1, 1, 1, 1 };
	float red[16], blue[16];

	for (int i = 0; i < 4; i++) {
		red[i * 4] = 1; red[i * 4 + 1] = 0; red[i * 4 + 2] = 0; red[i * 4 + 3] = 1;
		blue[i * 4] = 0; blue[i * 4 + 1] = 0; blue[i * 4 + 2] = 1; blue[i * 4 + 3] = 1;
	}
	uint16_t idx[6] = { 0, 1, 2, 2, 1, 3 };
	id<MTLBuffer> bidx = [device newBufferWithBytes:idx length:sizeof idx options:MTLResourceStorageModeShared];
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];

	rp.colorAttachments[0].texture = ms;
	rp.colorAttachments[0].resolveTexture = resolve;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
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
	[enc setVertexBytes:blue length:sizeof blue atIndex:1];
	[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:bidx indexBufferOffset:0];
	[enc endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	[resolve getBytes:px bytesPerRow:8 * 4 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
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
		pd.sampleCount = 4;
		id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:pd error:&err];

		if (!pso) {
			printf("metal_msaadepth: no render pipeline\n");
			return 2;
		}
		id<MTLCommandQueue> queue = [device newCommandQueue];
		uint8_t a[8 * 8 * 4], b[8 * 8 * 4];

		pass(device, queue, pso, MTLCompareFunctionLess, a);
		pass(device, queue, pso, MTLCompareFunctionLessEqual, b);
		uint8_t *p1 = a + (3 * 8 + 3) * 4, *p2 = b + (3 * 8 + 3) * 4;

		printf("metal_msaadepth: Less %02x%02x%02x; LessEqual %02x%02x%02x\n", p1[0], p1[1], p1[2], p2[0], p2[1], p2[2]);
		int ok = p1[0] > 250 && p1[2] < 5 && p2[2] > 250 && p2[0] < 5;

		printf("metal_msaadepth: %s\n", ok ? "MSAA DEPTH AS EXPECTED" : "WRONG");
		return ok ? 0 : 3;
	}
}
