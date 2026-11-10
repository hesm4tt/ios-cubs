/*
 * metal_samp: an ordinary Objective-C Metal program through libmtlshim.dylib: a 8x8 RGBA8 texture (left half red, right half blue) is filled
 * with replaceRegion:, bound with setFragmentTexture:atIndex: and sampled (linear filter, constexpr sampler in the fixture's sampled_fragment) by
 * a full-target quad into an 8x8 target (the fixture's shader maps the pixel position over an 8-texel side); two draws of one render pass (the second a small quad of the colored fragment) check that only the first
 * clears. The texels are read back and checked. Run by a launchd job list line "/redwood/bin/metal_samp".
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
		pd.fragmentFunction = [lib newFunctionWithName:@"sampled_fragment"];
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
		id<MTLRenderPipelineState> sampled = [device newRenderPipelineStateWithDescriptor:pd error:&err];
		MTLRenderPipelineDescriptor *pd2 = [[MTLRenderPipelineDescriptor alloc] init];

		pd2.vertexFunction = [lib newFunctionWithName:@"colored_vertex"];
		pd2.fragmentFunction = [lib newFunctionWithName:@"colored_fragment"];
		pd2.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
		id<MTLRenderPipelineState> plain = [device newRenderPipelineStateWithDescriptor:pd2 error:&err];

		if (!sampled || !plain) {
			printf("metal_samp: no render pipeline (%s)\n", err ? [[err description] UTF8String] : "?");
			return 2;
		}
		MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];

		sd.usage = MTLTextureUsageShaderRead;
		id<MTLTexture> source = [device newTextureWithDescriptor:sd];
		uint8_t texels[8 * 8 * 4];

		for (int y = 0; y < 8; y++) {
			for (int x = 0; x < 8; x++) {
				uint8_t *t = texels + (y * 8 + x) * 4;

				t[0] = x < 4 ? 255 : 0;
				t[1] = 0;
				t[2] = x < 4 ? 0 : 255;
				t[3] = 255;
			}
		}
		[source replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:texels bytesPerRow:8 * 4];
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];

		td.usage = MTLTextureUsageRenderTarget;
		id<MTLTexture> target = [device newTextureWithDescriptor:td];
		float quad[12] = { -1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1 };
		float small[12] = { -0.25f, -0.25f, 0.25f, -0.25f, -0.25f, 0.25f, -0.25f, 0.25f, 0.25f, -0.25f, 0.25f, 0.25f };
		float col[24], green[24];

		for (int i = 0; i < 6; i++) {
			col[i * 4] = 1; col[i * 4 + 1] = 1; col[i * 4 + 2] = 1; col[i * 4 + 3] = 1;
			green[i * 4] = 0; green[i * 4 + 1] = 1; green[i * 4 + 2] = 0; green[i * 4 + 3] = 1;
		}
		id<MTLBuffer> bquad = [device newBufferWithBytes:quad length:sizeof quad options:MTLResourceStorageModeShared];
		id<MTLBuffer> bsmall = [device newBufferWithBytes:small length:sizeof small options:MTLResourceStorageModeShared];
		id<MTLBuffer> bcol = [device newBufferWithBytes:col length:sizeof col options:MTLResourceStorageModeShared];
		id<MTLBuffer> bgreen = [device newBufferWithBytes:green length:sizeof green options:MTLResourceStorageModeShared];
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];

		rp.colorAttachments[0].texture = target;
		rp.colorAttachments[0].loadAction = MTLLoadActionClear;
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
		id<MTLCommandQueue> queue = [device newCommandQueue];
		id<MTLCommandBuffer> cb = [queue commandBuffer];
		id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];

		[enc setRenderPipelineState:sampled];
		[enc setVertexBuffer:bquad offset:0 atIndex:0];
		[enc setVertexBuffer:bcol offset:0 atIndex:1];
		[enc setFragmentTexture:source atIndex:0];
		MTLSamplerDescriptor *sdsc = [[MTLSamplerDescriptor alloc] init];

		sdsc.minFilter = MTLSamplerMinMagFilterLinear;
		sdsc.magFilter = MTLSamplerMinMagFilterLinear;
		sdsc.sAddressMode = MTLSamplerAddressModeRepeat;
		id<MTLSamplerState> samp = [device newSamplerStateWithDescriptor:sdsc];

		printf("metal_samp: sampler state %s\n", samp ? "made" : "NOT made");
		[enc setFragmentSamplerState:samp atIndex:0];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
		[enc setRenderPipelineState:plain];
		[enc setVertexBuffer:bsmall offset:0 atIndex:0];
		[enc setVertexBuffer:bgreen offset:0 atIndex:1];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
		[enc endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		uint8_t px[8 * 8 * 4];

		[target getBytes:px bytesPerRow:8 * 4 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
#define P(x, y) (px + ((y) * 8 + (x)) * 4)
		uint8_t *left = P(0, 1), *right = P(7, 1), *middle = P(4, 4), *edge = P(4, 0);

		printf("metal_samp: left %02x%02x%02x%02x right %02x%02x%02x%02x centre %02x%02x%02x%02x top-centre %02x%02x%02x%02x\n", left[0], left[1],
		    left[2], left[3], right[0], right[1], right[2], right[3], middle[0], middle[1], middle[2], middle[3], edge[0], edge[1], edge[2], edge[3]);
		int ok = left[0] > 200 && left[2] < 60 && right[2] > 200 && right[0] < 60 && middle[1] > 200 && middle[0] < 60;

		printf("metal_samp: %s\n", ok ? "SAMPLED TEXTURE AND SECOND DRAW AS EXPECTED" : "WRONG");
		return ok ? 0 : 3;
	}
}
