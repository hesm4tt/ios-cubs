/*
 * metal_triangle: an ordinary Objective-C Metal render program (render_to_texture of metal2vulkan written against the Metal
 * API): pipeline state from two library functions, a texture as render target cleared blue, two triangles over its top-left
 * quarter, the texels read back and checked. Linked with libmtlshim.dylib instead of Metal.framework.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "fixture_bc.h"

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
		id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:pd error:&err];

		if (!state) {
			printf("metal_triangle: no render pipeline\n");
			return 2;
		}
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
											     width:8 height:8 mipmapped:NO];

		td.usage = MTLTextureUsageRenderTarget;
		id<MTLTexture> target = [device newTextureWithDescriptor:td];
		float pos[12] = { -1, 1, 0, 1, -1, 0, 0, 1, 0, 0, -1, 0 };
		float col[24];

		for (int i = 0; i < 6; i++) {
			col[i * 4] = 1.0f; col[i * 4 + 1] = 0.2f; col[i * 4 + 2] = 0.0f; col[i * 4 + 3] = 1.0f;
		}
		id<MTLBuffer> bpos = [device newBufferWithBytes:pos length:sizeof pos options:MTLResourceStorageModeShared];
		id<MTLBuffer> bcol = [device newBufferWithBytes:col length:sizeof col options:MTLResourceStorageModeShared];
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];

		rp.colorAttachments[0].texture = target;
		rp.colorAttachments[0].loadAction = MTLLoadActionClear;
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1);
		id<MTLCommandQueue> queue = [device newCommandQueue];
		id<MTLCommandBuffer> cb = [queue commandBuffer];
		id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];

		[enc setRenderPipelineState:state];
		[enc setVertexBuffer:bpos offset:0 atIndex:0];
		[enc setVertexBuffer:bcol offset:0 atIndex:1];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
		[enc endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		uint8_t px[8 * 8 * 4];

		[target getBytes:px bytesPerRow:8 * 4 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
		int bad = 0;

		for (int y = 0; y < 8; y++) {
			for (int x = 0; x < 8; x++) {
				uint8_t *t = px + (y * 8 + x) * 4;
				int inside = x < 4 && y < 4;
				uint8_t want[4] = { inside ? 255 : 0, inside ? 51 : 0, inside ? 0 : 255, 255 };

				if (memcmp(t, want, 4)) {
					bad++;
				}
			}
		}
		if (bad) {
			printf("metal_triangle: %d wrong texels (first %02x%02x%02x%02x)\n", bad, px[0], px[1], px[2], px[3]);
			return 3;
		}
		printf("metal_triangle: Metal API render on the Linux GPU: every texel as expected\n");
	}
	return 0;
}
