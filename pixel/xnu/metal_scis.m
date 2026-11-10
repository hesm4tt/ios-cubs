/*
 * metal_scis: Metal through libmtlshim.dylib: indexed draws (UInt16 index buffer), setVertexBytes for the vertex data, and blending
 * (source alpha, one minus source alpha) in an 8x8 target: a red quad over all of it, then a half-transparent blue quad over its right half. Then fifty more
 * setVertexBytes draws in a loop (buffers made and freed by the shim). Checks: left red, right (red and blue 50 %) about 128,0,127.
 * Run by a launchd job list line "/redwood/bin/metal_scis".
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
		id<MTLRenderPipelineState> opaque = [device newRenderPipelineStateWithDescriptor:pd error:&err];

		pd.colorAttachments[0].blendingEnabled = YES;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		id<MTLRenderPipelineState> blended = [device newRenderPipelineStateWithDescriptor:pd error:&err];

		if (!opaque || !blended) {
			printf("metal_scis: no render pipeline\n");
			return 2;
		}
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];

		td.usage = MTLTextureUsageRenderTarget;
		id<MTLTexture> target = [device newTextureWithDescriptor:td];
		float full[8] = { -1, -1, 1, -1, -1, 1, 1, 1 };
		float right[8] = { 0, -1, 1, -1, 0, 1, 1, 1 };
		float red[16], blue[16];

		for (int i = 0; i < 4; i++) {
			red[i * 4] = 1; red[i * 4 + 1] = 0; red[i * 4 + 2] = 0; red[i * 4 + 3] = 1;
			blue[i * 4] = 0; blue[i * 4 + 1] = 0; blue[i * 4 + 2] = 1; blue[i * 4 + 3] = 0.5f;
		}
		uint16_t idx[6] = { 0, 1, 2, 2, 1, 3 };
		id<MTLBuffer> bidx = [device newBufferWithBytes:idx length:sizeof idx options:MTLResourceStorageModeShared];
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];

		rp.colorAttachments[0].texture = target;
		rp.colorAttachments[0].loadAction = MTLLoadActionClear;
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
		id<MTLCommandQueue> queue = [device newCommandQueue];
		id<MTLCommandBuffer> cb = [queue commandBuffer];
		id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];

		[enc setRenderPipelineState:opaque];
		[enc setVertexBytes:full length:sizeof full atIndex:0];
		[enc setVertexBytes:red length:sizeof red atIndex:1];
		[enc setScissorRect:(MTLScissorRect){ 4, 0, 4, 8 }];
		[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:bidx indexBufferOffset:0];
		[enc endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		uint8_t px[8 * 8 * 4];

		[target getBytes:px bytesPerRow:8 * 4 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
		uint8_t *left = px + (1 * 8 + 1) * 4, *rightp = px + (1 * 8 + 6) * 4;

		printf("metal_scis: left %02x%02x%02x%02x right %02x%02x%02x%02x\n", left[0], left[1], left[2], left[3], rightp[0], rightp[1], rightp[2], rightp[3]);
		int ok = left[0] < 5 && rightp[0] > 250;
		printf("metal_scis: %s\n", ok ? "SCISSOR AS EXPECTED" : "WRONG");
		return ok ? 0 : 3;
	}
}
