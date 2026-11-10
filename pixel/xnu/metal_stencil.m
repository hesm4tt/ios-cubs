/*
 * metal_stencil: stencil testing through libmtlshim.dylib in an 8x8 target with a Depth32Float_Stencil8 texture. Draw 1: a red quad over the right half with
 * stencil Always / pass op Replace, reference 1 (writes 1 there). Draw 2: a blue quad over everything with stencil Equal, reference 1: only the right half
 * (where the stencil is 1) is drawn. The left half stays the clear colour (black), the right ends blue.
 * Run by a launchd job list line "/redwood/bin/metal_stencil".
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
		pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
		pd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
		id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:pd error:&err];

		if (!pso) {
			printf("metal_stencil: no render pipeline\n");
			return 2;
		}
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];

		td.usage = MTLTextureUsageRenderTarget;
		id<MTLTexture> target = [device newTextureWithDescriptor:td];
		MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:8 height:8 mipmapped:NO];

		dd.usage = MTLTextureUsageRenderTarget;
		id<MTLTexture> ds = [device newTextureWithDescriptor:dd];
		MTLStencilDescriptor *wr = [[MTLStencilDescriptor alloc] init], *eq = [[MTLStencilDescriptor alloc] init];

		wr.stencilCompareFunction = MTLCompareFunctionAlways;
		wr.depthStencilPassOperation = MTLStencilOperationReplace;
		eq.stencilCompareFunction = MTLCompareFunctionEqual;
		MTLDepthStencilDescriptor *d1 = [[MTLDepthStencilDescriptor alloc] init], *d2 = [[MTLDepthStencilDescriptor alloc] init];

		d1.frontFaceStencil = wr;
		d1.backFaceStencil = wr;
		d2.frontFaceStencil = eq;
		d2.backFaceStencil = eq;
		id<MTLDepthStencilState> st1 = [device newDepthStencilStateWithDescriptor:d1], st2 = [device newDepthStencilStateWithDescriptor:d2];
		float full[8] = { -1, -1, 1, -1, -1, 1, 1, 1 };
		float right[8] = { 0, -1, 1, -1, 0, 1, 1, 1 };
		float red[16], blue[16];

		for (int i = 0; i < 4; i++) {
			red[i * 4] = 1; red[i * 4 + 1] = 0; red[i * 4 + 2] = 0; red[i * 4 + 3] = 1;
			blue[i * 4] = 0; blue[i * 4 + 1] = 0; blue[i * 4 + 2] = 1; blue[i * 4 + 3] = 1;
		}
		uint16_t idx[6] = { 0, 1, 2, 2, 1, 3 };
		id<MTLBuffer> bidx = [device newBufferWithBytes:idx length:sizeof idx options:MTLResourceStorageModeShared];
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];

		rp.colorAttachments[0].texture = target;
		rp.colorAttachments[0].loadAction = MTLLoadActionClear;
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
		rp.depthAttachment.texture = ds;
		rp.depthAttachment.loadAction = MTLLoadActionClear;
		rp.depthAttachment.storeAction = MTLStoreActionStore;
		rp.depthAttachment.clearDepth = 1.0;
		rp.stencilAttachment.texture = ds;
		rp.stencilAttachment.loadAction = MTLLoadActionClear;
		rp.stencilAttachment.storeAction = MTLStoreActionStore;
		rp.stencilAttachment.clearStencil = 0;
		id<MTLCommandQueue> queue = [device newCommandQueue];
		id<MTLCommandBuffer> cb = [queue commandBuffer];
		id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];

		[enc setRenderPipelineState:pso];
		[enc setDepthStencilState:st1];
		[enc setStencilReferenceValue:1];
		[enc setVertexBytes:right length:sizeof right atIndex:0];
		[enc setVertexBytes:red length:sizeof red atIndex:1];
		[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:bidx indexBufferOffset:0];
		[enc setDepthStencilState:st2];
		[enc setStencilReferenceValue:1];
		[enc setVertexBytes:full length:sizeof full atIndex:0];
		[enc setVertexBytes:blue length:sizeof blue atIndex:1];
		[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:bidx indexBufferOffset:0];
		[enc endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		uint8_t px[8 * 8 * 4];

		[target getBytes:px bytesPerRow:8 * 4 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
		uint8_t *l = px + (1 * 8 + 1) * 4, *r = px + (1 * 8 + 6) * 4;

		printf("metal_stencil: left %02x%02x%02x right %02x%02x%02x\n", l[0], l[1], l[2], r[0], r[1], r[2]);
		int ok = l[0] < 5 && l[2] < 5 && r[2] > 250 && r[0] < 5;

		printf("metal_stencil: %s\n", ok ? "STENCIL TEST AS EXPECTED" : "WRONG");
		return ok ? 0 : 3;
	}
}
