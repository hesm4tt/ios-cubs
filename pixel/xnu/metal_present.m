/*
 * metal_present: an ordinary Objective-C Metal program that animates a rotating triangle on a 360x640 render target and
 * presents every frame to the panel (MSPresentTexture of libmtlshim: the stand-in for presenting a CAMetalLayer drawable).
 * The GPU work runs on the Linux GPU server; XNU pastes the presented pixels into the display next to iOS own drawing.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "fixture_bc.h"

extern void MSPresentTexture(id<MTLTexture> texture, int x, int y);

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
			printf("metal_present: no render pipeline\n");
			return 2;
		}
		const int W = 360, H = 640;
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
											     width:W height:H mipmapped:NO];

		td.usage = MTLTextureUsageRenderTarget;
		id<MTLTexture> target = [device newTextureWithDescriptor:td];
		id<MTLCommandQueue> queue = [device newCommandQueue];
		id<MTLBuffer> bpos = [device newBufferWithLength:3 * 2 * 4 options:MTLResourceStorageModeShared];
		float col[12];

		for (int i = 0; i < 3; i++) {
			col[i * 4] = i == 0; col[i * 4 + 1] = i == 1; col[i * 4 + 2] = i == 2; col[i * 4 + 3] = 1.0f;
		}
		id<MTLBuffer> bcol = [device newBufferWithBytes:col length:sizeof col options:MTLResourceStorageModeShared];
		printf("metal_present: presenting\n");
		for (int frame = 0; frame < 900; frame++) {
			float a = frame * 0.08f, s = sinf(a), c = cosf(a);
			float tri[3][2] = { { 0.0f, -0.6f }, { 0.6f, 0.6f }, { -0.6f, 0.6f } };
			float pos[6];

			for (int i = 0; i < 3; i++) {
				pos[i * 2] = tri[i][0] * c - tri[i][1] * s;
				pos[i * 2 + 1] = (tri[i][0] * s + tri[i][1] * c) * ((float)W / H);
			}
			memcpy([bpos contents], pos, sizeof pos);
			MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];

			rp.colorAttachments[0].texture = target;
			rp.colorAttachments[0].loadAction = MTLLoadActionClear;
			rp.colorAttachments[0].storeAction = MTLStoreActionStore;
			rp.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.12, 1);
			id<MTLCommandBuffer> cb = [queue commandBuffer];
			id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];

			[enc setRenderPipelineState:state];
			[enc setVertexBuffer:bpos offset:0 atIndex:0];
			[enc setVertexBuffer:bcol offset:0 atIndex:1];
			[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
			[enc endEncoding];
			[cb commit];
			[cb waitUntilCompleted];
			MSPresentTexture(target, 0, 0);
			if (frame % 60 == 0) {
				printf("metal_present: frame %d\n", frame);
			}
			usleep(60000);
		}
		printf("metal_present: done\n");
	}
	return 0;
}
