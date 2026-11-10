/*
 * metal_compute2: the everyday compute encoder through libmtlshim.dylib: setTexture:atIndex: (a read and a write texture) with the fixture's invert_texels
 * kernel (texture2d<float, read> source, texture2d<float, write> destination), dispatched over an 8x8 grid. The inverse of every red/green/blue texel is checked.
 * Run by a launchd job list line "/redwood/bin/metal_compute2".
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
		id<MTLFunction> fn = [lib newFunctionWithName:@"invert_texels"];
		id<MTLComputePipelineState> pso = [device newComputePipelineStateWithFunction:fn error:&err];

		if (!pso) {
			printf("metal_compute2: no compute pipeline\n");
			return 2;
		}
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];

		td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
		id<MTLTexture> src = [device newTextureWithDescriptor:td], dst = [device newTextureWithDescriptor:td];
		uint8_t texels[8 * 8 * 4];

		for (int i = 0; i < 64; i++) {
			texels[i * 4] = (uint8_t)(i * 3);
			texels[i * 4 + 1] = (uint8_t)(100 + i);
			texels[i * 4 + 2] = 200;
			texels[i * 4 + 3] = 255;
		}
		[src replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:texels bytesPerRow:32];
		id<MTLCommandQueue> queue = [device newCommandQueue];
		id<MTLCommandBuffer> cb = [queue commandBuffer];
		id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];

		[enc setComputePipelineState:pso];
		[enc setTexture:src atIndex:0];
		[enc setTexture:dst atIndex:1];
		[enc dispatchThreads:MTLSizeMake(8, 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
		[enc endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		uint8_t out[8 * 8 * 4];

		[dst getBytes:out bytesPerRow:32 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
		int bad = 0;

		for (int i = 0; i < 64; i++) {
			for (int c = 0; c < 3; c++) {
				int want = 255 - texels[i * 4 + c], got = out[i * 4 + c];

				if (got < want - 1 || got > want + 1) {
					bad++;
				}
			}
		}
		printf("metal_compute2: texel 5: in %02x%02x%02x out %02x%02x%02x%02x, %d wrong channels\n", texels[20], texels[21], texels[22], out[20], out[21], out[22], out[23], bad);
		printf("metal_compute2: %s\n", bad == 0 ? "COMPUTE TEXTURES AS EXPECTED" : "WRONG");
		return bad == 0 ? 0 : 3;
	}
}
