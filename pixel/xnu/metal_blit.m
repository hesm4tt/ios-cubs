/*
 * metal_blit: blit encoder copies through libmtlshim.dylib: texture -> buffer, buffer -> texture, texture -> texture, buffer -> buffer, fillBuffer.
 * Run by a launchd job list line "/redwood/bin/metal_blit".
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
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];

		td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
		id<MTLTexture> a = [device newTextureWithDescriptor:td], b = [device newTextureWithDescriptor:td], c = [device newTextureWithDescriptor:td];
		uint8_t px[4 * 4 * 4];

		for (int i = 0; i < 16; i++) {
			px[i * 4] = i * 10; px[i * 4 + 1] = 100 + i; px[i * 4 + 2] = 200; px[i * 4 + 3] = 255;
		}
		[a replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:px bytesPerRow:16];
		id<MTLBuffer> buf = [device newBufferWithLength:64 options:MTLResourceStorageModeShared];
		id<MTLBuffer> buf2 = [device newBufferWithLength:64 options:MTLResourceStorageModeShared];
		id<MTLCommandQueue> queue = [device newCommandQueue];
		id<MTLCommandBuffer> cb = [queue commandBuffer];
		id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];

		[blit copyFromTexture:a sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(4, 4, 1) toBuffer:buf destinationOffset:0
		    destinationBytesPerRow:16 destinationBytesPerImage:64];
		[blit copyFromBuffer:buf sourceOffset:0 sourceBytesPerRow:16 sourceBytesPerImage:64 sourceSize:MTLSizeMake(4, 4, 1) toTexture:b destinationSlice:0
		    destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
		[blit copyFromTexture:b toTexture:c];
		[blit copyFromBuffer:buf sourceOffset:0 toBuffer:buf2 destinationOffset:0 size:64];
		[blit fillBuffer:buf2 range:NSMakeRange(0, 8) value:0xab];
		[blit endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		uint8_t got[64];

		[c getBytes:got bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
		int ok = !memcmp(got, px, 64) && !memcmp(buf.contents, px, 64) && ((uint8_t *)buf2.contents)[0] == 0xab && ((uint8_t *)buf2.contents)[7] == 0xab &&
		    !memcmp((uint8_t *)buf2.contents + 8, px + 8, 56);

		printf("metal_blit: texture->buffer->texture->texture copy %s, buffer copy and fill %s\n", !memcmp(got, px, 64) ? "ok" : "BAD",
		    ((uint8_t *)buf2.contents)[0] == 0xab ? "ok" : "BAD");
		printf("metal_blit: %s\n", ok ? "BLIT COPIES AS EXPECTED" : "WRONG");
		return ok ? 0 : 3;
	}
}
