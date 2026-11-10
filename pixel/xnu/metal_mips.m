/*
 * metal_mips: an 8x8 mipmapped RGBA8 texture (left half red, right half blue) is filled with replaceRegion:, its chain generated with a blit
 * encoder's generateMipmapsForTexture:, and level 2 (2x2) and level 3 (1x1) are read back. Also a replaceRegion straight into level 1 (4x4).
 * Run by a launchd job list line "/redwood/bin/metal_mips".
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

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
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:YES];

		td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
		id<MTLTexture> tex = [device newTextureWithDescriptor:td];
		uint8_t texels[8 * 8 * 4];

		for (int i = 0; i < 64; i++) {
			int x = i % 8;

			texels[i * 4] = x < 4 ? 255 : 0;
			texels[i * 4 + 1] = 0;
			texels[i * 4 + 2] = x < 4 ? 0 : 255;
			texels[i * 4 + 3] = 255;
		}
		[tex replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:texels bytesPerRow:32];
		id<MTLCommandQueue> queue = [device newCommandQueue];
		id<MTLCommandBuffer> cb = [queue commandBuffer];
		id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];

		[blit generateMipmapsForTexture:tex];
		[blit endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		uint8_t l2[2 * 2 * 4], l3[4];

		[tex getBytes:l2 bytesPerRow:8 fromRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:2];
		[tex getBytes:l3 bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:3];
		uint8_t put[4 * 4 * 4], l1[4 * 4 * 4];

		for (int i = 0; i < 16; i++) {
			put[i * 4] = 10; put[i * 4 + 1] = 20; put[i * 4 + 2] = 30; put[i * 4 + 3] = 255;
		}
		[tex replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:1 withBytes:put bytesPerRow:16];
		[tex getBytes:l1 bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:1];
		printf("metal_mips: levels %lu; level2 left %02x%02x%02x%02x right %02x%02x%02x%02x; level3 %02x%02x%02x%02x; level1 put/get %02x%02x%02x%02x\n",
		    (unsigned long)[tex mipmapLevelCount], l2[0], l2[1], l2[2], l2[3], l2[4], l2[5], l2[6], l2[7], l3[0], l3[1], l3[2], l3[3], l1[0], l1[1], l1[2], l1[3]);
		int ok = [tex mipmapLevelCount] == 4 && l2[0] > 250 && l2[2] < 5 && l2[4] < 5 && l2[6] > 250 && l3[0] > 120 && l3[0] < 136 && l3[2] > 120 && l3[2] < 136 &&
		    !memcmp(put, l1, sizeof put);

		printf("metal_mips: %s\n", ok ? "MIPMAPS AS EXPECTED" : "WRONG");
		return ok ? 0 : 3;
	}
}
