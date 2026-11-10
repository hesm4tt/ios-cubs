/*
 * metal_occ: occlusion queries through libmtlshim.dylib. A visibility result buffer (3 slots of 8 bytes). Slot 0, counting mode: a full 8x8 quad (64 samples)
 * then a right-half quad (32 more) = 96. Slot 1, boolean mode: a quad outside the clip volume = 0. Slot 2, boolean mode: a visible quad = 1.
 * Run by a launchd job list line "/redwood/bin/metal_occ".
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
		id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:pd error:&err];

		if (!pso) {
			printf("metal_occ: no render pipeline\n");
			return 2;
		}
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];

		td.usage = MTLTextureUsageRenderTarget;
		id<MTLTexture> target = [device newTextureWithDescriptor:td];
		id<MTLBuffer> vis = [device newBufferWithLength:24 options:MTLResourceStorageModeShared];

		memset(vis.contents, 0, 24);
		float full[8] = { -1, -1, 1, -1, -1, 1, 1, 1 };
		float right[8] = { 0, -1, 1, -1, 0, 1, 1, 1 };
		float away[8] = { 2, 2, 3, 2, 2, 3, 3, 3 };
		float red[16];

		for (int i = 0; i < 4; i++) {
			red[i * 4] = 1; red[i * 4 + 1] = 0; red[i * 4 + 2] = 0; red[i * 4 + 3] = 1;
		}
		uint16_t idx[6] = { 0, 1, 2, 2, 1, 3 };
		id<MTLBuffer> bidx = [device newBufferWithBytes:idx length:sizeof idx options:MTLResourceStorageModeShared];
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];

		rp.colorAttachments[0].texture = target;
		rp.colorAttachments[0].loadAction = MTLLoadActionClear;
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
		rp.visibilityResultBuffer = vis;
		id<MTLCommandQueue> queue = [device newCommandQueue];
		id<MTLCommandBuffer> cb = [queue commandBuffer];
		id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];

		[enc setRenderPipelineState:pso];
		[enc setVertexBytes:red length:sizeof red atIndex:1];
		[enc setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
		[enc setVertexBytes:full length:sizeof full atIndex:0];
		[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:bidx indexBufferOffset:0];
		[enc setVertexBytes:right length:sizeof right atIndex:0];
		[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:bidx indexBufferOffset:0];
		[enc setVisibilityResultMode:MTLVisibilityResultModeBoolean offset:8];
		[enc setVertexBytes:away length:sizeof away atIndex:0];
		[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:bidx indexBufferOffset:0];
		[enc setVisibilityResultMode:MTLVisibilityResultModeBoolean offset:16];
		[enc setVertexBytes:right length:sizeof right atIndex:0];
		[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:bidx indexBufferOffset:0];
		[enc setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
		[enc endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		uint64_t *res = (uint64_t *)vis.contents;

		printf("metal_occ: counting %llu, boolean offscreen %llu, boolean visible %llu\n", res[0], res[1], res[2]);
		int ok = res[0] == 96 && res[1] == 0 && res[2] == 1;

		printf("metal_occ: %s\n", ok ? "OCCLUSION QUERIES AS EXPECTED" : "WRONG");
		return ok ? 0 : 3;
	}
}
