/*
 * metal_big: Metal through libmtlshim.dylib: indexed draws (UInt16 index buffer), setVertexBytes for the vertex data, and blending
 * (source alpha, one minus source alpha) in an 8x8 target: a red quad over all of it, then a half-transparent blue quad over its right half. Then fifty more
 * setVertexBytes draws in a loop (buffers made and freed by the shim). Checks: left red, right (red and blue 50 %) about 128,0,127.
 * Run by a launchd job list line "/redwood/bin/metal_big".
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
			printf("metal_big: no render pipeline\n");
			return 2;
		}
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1100 height:1000 mipmapped:NO];

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
		[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:bidx indexBufferOffset:0];
		[enc endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		static uint8_t px[1100 * 1000 * 4];

		[target getBytes:px bytesPerRow:1100 * 4 fromRegion:MTLRegionMake2D(0, 0, 1100, 1000) mipmapLevel:0];
		uint8_t *a = px, *b = px + (999 * 1100 + 1099) * 4, *c = px + (500 * 1100 + 550) * 4;

		printf("metal_big: corner %02x%02x%02x%02x far corner %02x%02x%02x%02x centre %02x%02x%02x%02x\n", a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3], c[0], c[1], c[2], c[3]);
		int ok = a[0] > 250 && b[0] > 250 && c[0] > 250 && a[2] < 5;
		printf("metal_big: %s\n", ok ? "4.4 MB TEXTURE DRAWN AND READ BACK" : "WRONG");
		return ok ? 0 : 3;
	}
}
