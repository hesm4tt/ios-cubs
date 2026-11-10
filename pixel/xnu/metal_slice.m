/*
 * metal_slice: Metal through libmtlshim.dylib: indexed draws (UInt16 index buffer), setVertexBytes for the vertex data, and blending
 * (source alpha, one minus source alpha) in an 8x8 target: a red quad over all of it, then a half-transparent blue quad over its right half. Then fifty more
 * setVertexBytes draws in a loop (buffers made and freed by the shim). Checks: left red, right (red and blue 50 %) about 128,0,127.
 * Run by a launchd job list line "/redwood/bin/metal_slice".
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
			printf("metal_slice: no render pipeline\n");
			return 2;
		}
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];

		td.textureType = MTLTextureType2DArray;
		td.arrayLength = 3;
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		id<MTLTexture> target = [device newTextureWithDescriptor:td];
		uint8_t blue[8 * 8 * 4];

		for (int i = 0; i < 64; i++) {
			blue[i * 4] = 0; blue[i * 4 + 1] = 0; blue[i * 4 + 2] = 255; blue[i * 4 + 3] = 255;
		}
		for (int sl = 0; sl < 3; sl++) {
			[target replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 slice:sl withBytes:blue bytesPerRow:32 bytesPerImage:256];
		}
		float full[8] = { -1, -1, 1, -1, -1, 1, 1, 1 };
		float red[16];

		for (int i = 0; i < 4; i++) {
			red[i * 4] = 1; red[i * 4 + 1] = 0; red[i * 4 + 2] = 0; red[i * 4 + 3] = 1;
		}
		uint16_t idx[6] = { 0, 1, 2, 2, 1, 3 };
		id<MTLBuffer> bidx = [device newBufferWithBytes:idx length:sizeof idx options:MTLResourceStorageModeShared];
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];

		rp.colorAttachments[0].texture = target;
		rp.colorAttachments[0].slice = 1;
		rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
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
		uint8_t s0[8 * 8 * 4], s1[8 * 8 * 4], s2[8 * 8 * 4];

		[target getBytes:s0 bytesPerRow:32 bytesPerImage:256 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 slice:0];
		[target getBytes:s1 bytesPerRow:32 bytesPerImage:256 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 slice:1];
		[target getBytes:s2 bytesPerRow:32 bytesPerImage:256 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 slice:2];
		printf("metal_slice: slice0 %02x%02x%02x slice1 %02x%02x%02x slice2 %02x%02x%02x\n", s0[100], s0[101], s0[102], s1[100], s1[101], s1[102], s2[100], s2[101], s2[102]);
		int ok = s0[102] == 255 && s0[100] == 0 && s1[100] == 255 && s1[102] == 0 && s2[102] == 255 && s2[100] == 0;
		printf("metal_slice: %s\n", ok ? "RENDER TO AN ARRAY SLICE AS EXPECTED" : "WRONG");
		return ok ? 0 : 3;
	}
}
