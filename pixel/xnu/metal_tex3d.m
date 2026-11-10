/*
 * metal_tex3d: 2D array, cube and 3D textures through libmtlshim.dylib. Each slice, face or depth plane is filled with its own colour (replaceRegion with a slice
 * or with a region of several depth planes) and read back (getBytes with a slice, or with a region of several depth planes); every one must return its own colour.
 * Run by a launchd job list line "/redwood/bin/metal_tex3d".
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern id<MTLDevice> MTLCreateSystemDefaultDevice(void);

static void
fill(uint8_t *px, int n, uint8_t r, uint8_t g, uint8_t b)
{
	for (int i = 0; i < n; i++) {
		px[i * 4] = r; px[i * 4 + 1] = g; px[i * 4 + 2] = b; px[i * 4 + 3] = 255;
	}
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
		int bad = 0;
		uint8_t img[4 * 4 * 4], got[4 * 4 * 4];
		/* 2D array: 3 slices of 4x4 */
		MTLTextureDescriptor *ad = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];

		ad.textureType = MTLTextureType2DArray;
		ad.arrayLength = 3;
		ad.usage = MTLTextureUsageShaderRead;
		id<MTLTexture> arr = [device newTextureWithDescriptor:ad];

		for (int sl = 0; sl < 3; sl++) {
			fill(img, 16, 10 + sl * 40, 20, 200 - sl * 50);
			[arr replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 slice:sl withBytes:img bytesPerRow:16 bytesPerImage:64];
		}
		for (int sl = 0; sl < 3; sl++) {
			[arr getBytes:got bytesPerRow:16 bytesPerImage:64 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 slice:sl];
			if (got[0] != 10 + sl * 40 || got[2] != 200 - sl * 50 || got[60] != 10 + sl * 40) {
				bad++;
			}
		}
		/* cube: 6 faces of 4x4 */
		MTLTextureDescriptor *cd = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm size:4 mipmapped:NO];

		cd.usage = MTLTextureUsageShaderRead;
		id<MTLTexture> cube = [device newTextureWithDescriptor:cd];

		for (int f = 0; f < 6; f++) {
			fill(img, 16, 30 * f, 100, 7 + f);
			[cube replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 slice:f withBytes:img bytesPerRow:16 bytesPerImage:64];
		}
		for (int f = 0; f < 6; f++) {
			[cube getBytes:got bytesPerRow:16 bytesPerImage:64 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 slice:f];
			if (got[0] != 30 * f || got[2] != 7 + f) {
				bad++;
			}
		}
		/* 3D: 4x4x3, one region of three planes */
		MTLTextureDescriptor *vd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];

		vd.textureType = MTLTextureType3D;
		vd.depth = 3;
		vd.usage = MTLTextureUsageShaderRead;
		id<MTLTexture> vol = [device newTextureWithDescriptor:vd];
		uint8_t planes[3 * 64], back[3 * 64];

		for (int z = 0; z < 3; z++) {
			fill(planes + z * 64, 16, 50 + z * 60, 9, 90 + z);
		}
		[vol replaceRegion:MTLRegionMake3D(0, 0, 0, 4, 4, 3) mipmapLevel:0 slice:0 withBytes:planes bytesPerRow:16 bytesPerImage:64];
		[vol getBytes:back bytesPerRow:16 bytesPerImage:64 fromRegion:MTLRegionMake3D(0, 0, 0, 4, 4, 3) mipmapLevel:0 slice:0];
		for (int z = 0; z < 3; z++) {
			if (back[z * 64] != 50 + z * 60 || back[z * 64 + 2] != 90 + z) {
				bad++;
			}
		}
		printf("metal_tex3d: types array %lu cube %lu 3d %lu, array length %lu, depth %lu; %d wrong\n", (unsigned long)arr.textureType, (unsigned long)cube.textureType,
		    (unsigned long)vol.textureType, (unsigned long)arr.arrayLength, (unsigned long)vol.depth, bad);
		int ok = bad == 0 && arr.textureType == MTLTextureType2DArray && cube.textureType == MTLTextureTypeCube && vol.textureType == MTLTextureType3D;

		printf("metal_tex3d: %s\n", ok ? "ARRAY, CUBE AND 3D TEXTURES AS EXPECTED" : "WRONG");
		return ok ? 0 : 3;
	}
}
