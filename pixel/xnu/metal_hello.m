/*
 * metal_hello: an ordinary Objective-C Metal compute program (the compute_dispatch example of metal2vulkan written against the
 * Metal API), run on iOS on the Pixel. It imports <Metal/Metal.h> for declarations only and is linked with libmtlshim.dylib
 * instead of Metal.framework, so MTLCreateSystemDefaultDevice() is the shim's and the work runs on the Linux GPU server.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
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
				if (tries % 30 == 0) {
					printf("metal_hello: no Metal device yet (try %d)\n", tries);
				}
				sleep(2);
			}
		}
		if (!device) {
			return 1;
		}
		printf("metal_hello: device %s\n", [[device name] UTF8String]);
		dispatch_data_t data = dispatch_data_create(fixture_bc, fixture_bc_len, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
		NSError *err = nil;
		id<MTLLibrary> lib = [device newLibraryWithData:data error:&err];
		id<MTLFunction> fn = [lib newFunctionWithName:@"scale_and_offset"];
		id<MTLComputePipelineState> pso = [device newComputePipelineStateWithFunction:fn error:&err];

		if (!pso) {
			printf("metal_hello: no pipeline\n");
			return 2;
		}
		enum { N = 1000 };
		float in[N];
		float scale = 2.0f;

		for (int i = 0; i < N; i++) {
			in[i] = (float)i;
		}
		id<MTLBuffer> bin = [device newBufferWithBytes:in length:sizeof in options:MTLResourceStorageModeShared];
		id<MTLBuffer> bout = [device newBufferWithLength:sizeof in options:MTLResourceStorageModeShared];
		id<MTLBuffer> bsc = [device newBufferWithBytes:&scale length:4 options:MTLResourceStorageModeShared];
		id<MTLCommandQueue> queue = [device newCommandQueue];
		id<MTLCommandBuffer> cb = [queue commandBuffer];
		id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];

		[enc setComputePipelineState:pso];
		[enc setBuffer:bin offset:0 atIndex:0];
		[enc setBuffer:bout offset:0 atIndex:1];
		[enc setBuffer:bsc offset:0 atIndex:2];
		[enc dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
		[enc endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		float *out = [bout contents];
		int bad = 0;

		for (int i = 0; i < N; i++) {
			if (out[i] != 3.0f * (float)i) {
				bad++;
			}
		}
		if (bad) {
			printf("metal_hello: %d wrong outputs, out[1] = %f\n", bad, out[1]);
			return 3;
		}
		printf("metal_hello: Metal API compute on the Linux GPU: output[999] = %.0f as expected\n", out[N - 1]);
	}
	return 0;
}
