/*
 * libmtlshim: a minimal Metal API surface for iOS on the Pixel, executed by the Linux GPU server (mtlsrv, metal2vulkan on the
 * PowerVR) through /dev/cubs-gpu. A program that imports <Metal/Metal.h> for the declarations and links THIS library instead of
 * Metal.framework gets, from MTLCreateSystemDefaultDevice(), a device whose compute path works:
 *   newLibraryWithData: (AIR bitcode or metallib) -> newFunctionWithName: -> newComputePipelineStateWithFunction:
 *   newBufferWithLength:/Bytes: (contents are host memory, synchronised around each command buffer)
 *   commandQueue -> commandBuffer -> computeCommandEncoder: setComputePipelineState/setBuffer/dispatchThreads(groups)
 *   commit, waitUntilCompleted.
 * Everything else answers nil/0 (the full route is upstream's redwoodmetal.m plugin on the real Metal.framework, with its rwa_*
 * contract implemented over this same RPC). Protocol of mtlsrv: see pcwork/gpusrv/src/bin/mtlsrv.rs.
 * Built without ARC (-fno-objc-arc), linked with -lobjc -framework Foundation.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAMetalLayer.h>
#include <objc/runtime.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/time.h>
#include <unistd.h>

#define RPC_OFF 0xB00000
#define PAYLOAD_OFF (RPC_OFF + 0x1000)
#define PAYLOAD_MAX 0x300000

static int g_fd = -1;
static uint32_t g_seq;
static NSLock *g_lock;

static uint32_t
rpc_word(int i)
{
	uint32_t v = 0;

	(void)pread(g_fd, &v, 4, RPC_OFF + i * 4);
	return v;
}

static void
rpc_setword(int i, uint32_t v)
{
	(void)pwrite(g_fd, &v, 4, RPC_OFF + i * 4);
}

static double
rpc_now(void)
{
	struct timeval tv;

	gettimeofday(&tv, NULL);
	return tv.tv_sec + tv.tv_usec / 1e6;
}

static int
rpc_open(void)
{
	if (g_fd >= 0) {
		return 1;
	}
	g_fd = open("/dev/cubs-gpu", O_RDWR);
	if (g_fd < 0 || rpc_word(0) != 0x4d544c31u) {
		if (g_fd >= 0) {
			close(g_fd);
			g_fd = -1;
		}
		return 0;
	}
	g_seq = rpc_word(1);
	return 1;
}

/* one call; returns the status (0 ok). result gets the id word, resp (capacity cap) the response bytes. */
static uint32_t
rpc_call(uint32_t op, const void *payload, uint32_t plen, uint32_t *result, void *resp, uint32_t cap, uint32_t *rlen)
{
	[g_lock lock];
	/* other processes use the same mailbox: take a file lock for the whole call, and read the counter inside it */
	static int lockfd = -2;

	if (lockfd == -2) {
		lockfd = open("/tmp/mtlshim.lock", O_RDWR | O_CREAT, 0666);
	}
	if (lockfd >= 0) {
		flock(lockfd, LOCK_EX);
	}
	if (plen) {
		(void)pwrite(g_fd, payload, plen, PAYLOAD_OFF);
	}
	rpc_setword(4, op);
	rpc_setword(6, plen);
	g_seq = rpc_word(1) + 1;
	rpc_setword(1, g_seq);
	double t = rpc_now();

	while (rpc_word(2) != g_seq) {
		if (rpc_now() - t > 30) {
			if (lockfd >= 0) {
				flock(lockfd, LOCK_UN);
			}
			[g_lock unlock];
			return 99;
		}
		usleep(300);
	}
	uint32_t status = rpc_word(3), n = rpc_word(6);

	if (result) {
		*result = rpc_word(5);
	}
	if (resp && n && n <= cap) {
		(void)pread(g_fd, resp, n, PAYLOAD_OFF);
	}
	if (rlen) {
		*rlen = n;
	}
	if (lockfd >= 0) {
		flock(lockfd, LOCK_UN);
	}
	[g_lock unlock];
	return status;
}

/* ------------------------------------------------------------------------------------------------ objects */

@interface MSDevice : NSObject <MTLDevice>
@end
@interface MSLibrary : NSObject <MTLLibrary>
@property (nonatomic) uint32_t rid;
@end
@interface MSFunction : NSObject <MTLFunction>
@property (nonatomic, retain) MSLibrary *lib;
@property (nonatomic, copy) NSString *fname;
@end
@interface MSPipeline : NSObject <MTLComputePipelineState>
@property (nonatomic) uint32_t rid;
@property (nonatomic) NSUInteger maxThreads;
@end
@interface MSBuffer : NSObject <MTLBuffer>
@property (nonatomic) uint32_t rid;
@property (nonatomic) NSUInteger len;
@property (nonatomic) void *mem;
@end
@interface MSQueue : NSObject <MTLCommandQueue>
@end
@interface MSCommandBuffer : NSObject <MTLCommandBuffer>
@property (nonatomic, retain) NSMutableArray *dispatches;
@property (nonatomic) MTLCommandBufferStatus st;
@property (nonatomic, retain) NSMutableArray *presents;
@property (nonatomic, retain) NSMutableArray *handlers;
@end
@interface MSTexture : NSObject <MTLTexture>
@property (nonatomic) uint32_t rid;
@property (nonatomic) NSUInteger w, h;
@property (nonatomic) MTLPixelFormat fmt;
@property (nonatomic) NSUInteger mips, samples, ttype, dep, alen;
@end
@interface MSDrawable : NSObject <CAMetalDrawable>
@property (nonatomic, retain) MSTexture *tex;
@property (nonatomic, assign) CAMetalLayer *lay;
@property (nonatomic) NSUInteger did;
@end
@interface MSRenderPipeline : NSObject <MTLRenderPipelineState>
@property (nonatomic) uint32_t rid;
@end
@interface MSRenderEncoder : NSObject <MTLRenderCommandEncoder> {
@public
	float clear[4];
	BOOL load_clears, depth_load_clears;
	unsigned drawn;
	uint32_t dsid, cull, winding;
	double clear_depth;
	uint32_t clear_stencil, sref_f, sref_b;
	uint32_t pend_inst, pend_binst;
	NSDictionary *pend_ind;
	uint32_t vis_mode, vis_off, vis_region;
	uint32_t tlevel, tslice;
	BOOL vis_first;
	int32_t pend_bvert;
	BOOL stencil_load_clears;
}
@property (nonatomic, retain) MSTexture *depth, *stex, *rtex;
@property (nonatomic, retain) id<MTLBuffer> visbuf;
@property (nonatomic, retain) NSMutableDictionary *ftex;
@property (nonatomic, retain) NSMutableDictionary *fbound, *fsamp;
@property (nonatomic, retain) NSData *vpdata, *scdata;
@property (nonatomic, retain) NSMutableDictionary *vtex, *vsamp;
@property (nonatomic, assign) MSCommandBuffer *cb;
@property (nonatomic, retain) MSRenderPipeline *pso;
@property (nonatomic, retain) MSTexture *target;
@property (nonatomic, retain) NSMutableDictionary *bound;
@end
@interface MSComputeEncoder : NSObject <MTLComputeCommandEncoder>
@property (nonatomic, retain) NSMutableDictionary *ctex, *tgmem;
@property (nonatomic, assign) MSCommandBuffer *cb;
@property (nonatomic, retain) MSPipeline *pso;
@property (nonatomic, retain) NSMutableDictionary *bound; /* index -> {buffer, offset} */
@end

@interface MSDepthStencilState : NSObject <MTLDepthStencilState>
@property (nonatomic) uint32_t rid;
@end
@implementation MSDepthStencilState
- (void)dealloc
{
	if (self.rid) {
		uint32_t a[2] = { 6, self.rid };

		(void)rpc_call(14, a, sizeof a, NULL, NULL, 0, NULL);
	}
	[super dealloc];
}
- (NSString *)label { return nil; }
- (id<MTLDevice>)device { return nil; }
@end

@interface MSSampler : NSObject <MTLSamplerState>
@property (nonatomic) uint32_t rid;
@end
@implementation MSSampler
- (void)dealloc
{
	if (self.rid) {
		uint32_t a[2] = { 7, self.rid };

		(void)rpc_call(14, a, sizeof a, NULL, NULL, 0, NULL); /* NEW_SAMPLER's object */
	}
	[super dealloc];
}
- (NSString *)label { return nil; }
- (id<MTLDevice>)device { return nil; }
@end

@implementation MSDevice
- (id<MTLDepthStencilState>)newDepthStencilStateWithDescriptor:(MTLDepthStencilDescriptor *)d
{
	uint32_t p[14] = { (uint32_t)d.depthCompareFunction, d.depthWriteEnabled ? 1u : 0u }, rid = 0;
	MTLStencilDescriptor *faces[2] = { d.frontFaceStencil, d.backFaceStencil };

	for (int i = 0; i < 2; i++) {
		uint32_t *q = &p[2 + i * 6];
		MTLStencilDescriptor *f = faces[i];

		q[0] = f ? (uint32_t)f.stencilCompareFunction : (uint32_t)MTLCompareFunctionAlways;
		q[1] = f ? (uint32_t)f.stencilFailureOperation : 0;
		q[2] = f ? (uint32_t)f.depthFailureOperation : 0;
		q[3] = f ? (uint32_t)f.depthStencilPassOperation : 0;
		q[4] = f ? (uint32_t)f.readMask : 0xffffffffu;
		q[5] = f ? (uint32_t)f.writeMask : 0xffffffffu;
	}

	if (rpc_call(16, p, sizeof p, &rid, NULL, 0, NULL) != 0) {
		return nil;
	}
	MSDepthStencilState *st = [[MSDepthStencilState alloc] init];

	st.rid = rid;
	return st;
}
- (id<MTLSamplerState>)newSamplerStateWithDescriptor:(MTLSamplerDescriptor *)d
{
	float lmin = d.lodMinClamp, lmax = d.lodMaxClamp;
	uint32_t p[12] = { (uint32_t)d.minFilter, (uint32_t)d.magFilter, (uint32_t)d.mipFilter, (uint32_t)d.sAddressMode, (uint32_t)d.tAddressMode,
			   (uint32_t)d.rAddressMode, (uint32_t)d.borderColor, d.normalizedCoordinates ? 1u : 0u, 0, 0, (uint32_t)d.maxAnisotropy,
			   (uint32_t)d.compareFunction }, rid = 0;

	memcpy(&p[8], &lmin, 4);
	memcpy(&p[9], &lmax, 4);
	if (rpc_call(17, p, sizeof p, &rid, NULL, 0, NULL) != 0) {
		return nil; /* NEW_SAMPLER */
	}
	MSSampler *st = [[MSSampler alloc] init];

	st.rid = rid;
	return st;
}
- (NSString *)name { return @"Pixel 11 PowerVR (Linux GPU server, metal2vulkan)"; }
- (id<MTLCommandQueue>)newCommandQueue { return [[MSQueue alloc] init]; }
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options
{
	return [self newBufferWithBytes:NULL length:length options:options];
}
- (id<MTLBuffer>)newBufferWithBytes:(const void *)pointer length:(NSUInteger)length options:(MTLResourceOptions)options
{
	MSBuffer *b = [[MSBuffer alloc] init];
	uint8_t *p = malloc(8 + (pointer ? length : 0));
	uint32_t l = (uint32_t)length, has = pointer != NULL, rid = 0;

	b.len = length;
	b.mem = calloc(1, length ? length : 1);
	if (pointer) {
		memcpy(b.mem, pointer, length);
	}
	memcpy(p, &l, 4);
	memcpy(p + 4, &has, 4);
	if (pointer) {
		memcpy(p + 8, pointer, length);
	}
	if (rpc_call(2, p, 8 + (pointer ? (uint32_t)length : 0), &rid, NULL, 0, NULL) != 0) {
		free(p);
		return nil;
	}
	free(p);
	b.rid = rid;
	return b;
}
- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error
{
	const void *bytes = NULL;
	size_t n = 0;
	dispatch_data_t map = dispatch_data_create_map(data, &bytes, &n);
	uint32_t rid = 0;
	uint32_t st = rpc_call(1, bytes, (uint32_t)n, &rid, NULL, 0, NULL);

	(void)map;
	if (st != 0) {
		if (error) {
			*error = [NSError errorWithDomain:@"MTLLibraryErrorDomain" code:1 userInfo:nil];
		}
		return nil;
	}
	MSLibrary *l = [[MSLibrary alloc] init];

	l.rid = rid;
	return l;
}
- (id<MTLLibrary>)newLibraryWithURL:(NSURL *)url error:(NSError **)error
{
	NSData *d = [NSData dataWithContentsOfURL:url];

	if (!d) {
		if (error) {
			*error = [NSError errorWithDomain:@"MTLLibraryErrorDomain" code:2 userInfo:nil];
		}
		return nil;
	}
	dispatch_data_t dd = dispatch_data_create(d.bytes, d.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);

	return [self newLibraryWithData:dd error:error];
}
- (id<MTLLibrary>)newLibraryWithFile:(NSString *)path error:(NSError **)error
{
	return [self newLibraryWithURL:[NSURL fileURLWithPath:path] error:error];
}
- (id<MTLLibrary>)newDefaultLibraryWithBundle:(NSBundle *)bundle error:(NSError **)error
{
	NSString *p = [bundle pathForResource:@"default" ofType:@"metallib"];

	if (!p) {
		p = [[bundle resourcePath] stringByAppendingPathComponent:@"default.metallib"];
	}
	if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
		p = [[bundle bundlePath] stringByAppendingPathComponent:@"default.metallib"];
	}
	return [self newLibraryWithFile:p error:error];
}
- (id<MTLLibrary>)newDefaultLibrary
{
	return [self newDefaultLibraryWithBundle:[NSBundle mainBundle] error:NULL];
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)function error:(NSError **)error
{
	MSFunction *f = (MSFunction *)function;
	NSData *nm = [f.fname dataUsingEncoding:NSUTF8StringEncoding];
	uint8_t p[256];
	uint32_t lib = f.lib.rid, rid = 0;

	memcpy(p, &lib, 4);
	memcpy(p + 4, nm.bytes, nm.length);
	if (rpc_call(5, p, 4 + (uint32_t)nm.length, &rid, NULL, 0, NULL) != 0) {
		if (error) {
			*error = [NSError errorWithDomain:@"MTLLibraryErrorDomain" code:2 userInfo:nil];
		}
		return nil;
	}
	MSPipeline *s = [[MSPipeline alloc] init];

	s.rid = rid;
	s.maxThreads = rpc_word(7);
	return s;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d
{
	uint32_t p[9] = { (uint32_t)d.width, (uint32_t)d.height, ((d.usage & MTLTextureUsageShaderRead) ? 1u : 0u) | ((d.usage & MTLTextureUsageShaderWrite) ? 2u : 0u),
			  (d.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 ? 2u : (d.pixelFormat == MTLPixelFormatDepth32Float ? 1u : 0u)), d.mipmapLevelCount > 1 ? 1u : 0u, (uint32_t)(d.sampleCount > 1 ? d.sampleCount : 1),
			  (uint32_t)d.textureType, (uint32_t)(d.depth ? d.depth : 1), (uint32_t)(d.arrayLength ? d.arrayLength : 1) }, rid = 0;

	if (rpc_call(7, p, sizeof p, &rid, NULL, 0, NULL) != 0) {
		return nil;
	}
	MSTexture *t = [[MSTexture alloc] init];

	t.rid = rid;
	t.w = d.width;
	t.h = d.height;
	t.fmt = d.pixelFormat;
	t.mips = d.mipmapLevelCount ? d.mipmapLevelCount : 1;
	t.samples = d.sampleCount > 1 ? d.sampleCount : 1; /* MSAA */
	t.ttype = d.textureType;
	t.dep = d.depth ? d.depth : 1;
	t.alen = d.arrayLength ? d.arrayLength : 1;
	return t;
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d error:(NSError **)error
{
	MSFunction *vf = (MSFunction *)d.vertexFunction, *ff = (MSFunction *)d.fragmentFunction;
	NSData *vn = [vf.fname dataUsingEncoding:NSUTF8StringEncoding], *fnn = [ff.fname dataUsingEncoding:NSUTF8StringEncoding];
	NSMutableData *p = [NSMutableData data];
	uint32_t lib = vf.lib.rid, vl = (uint32_t)vn.length, rid = 0;
	MTLRenderPipelineColorAttachmentDescriptor *ca = d.colorAttachments[0];
	uint32_t blend[10] = { ca.blendingEnabled ? 1u : 0u, (uint32_t)ca.sourceRGBBlendFactor, (uint32_t)ca.destinationRGBBlendFactor,
			      (uint32_t)ca.rgbBlendOperation, (uint32_t)ca.sourceAlphaBlendFactor, (uint32_t)ca.destinationAlphaBlendFactor,
			      (uint32_t)ca.alphaBlendOperation, (uint32_t)ca.writeMask, (d.depthAttachmentPixelFormat == MTLPixelFormatDepth32Float_Stencil8 || d.stencilAttachmentPixelFormat == MTLPixelFormatDepth32Float_Stencil8) ? 2u : (d.depthAttachmentPixelFormat == MTLPixelFormatDepth32Float ? 1u : 0u), (uint32_t)(d.sampleCount > 1 ? d.sampleCount : (d.rasterSampleCount > 1 ? d.rasterSampleCount : 1)) };

	[p appendBytes:&lib length:4];
	[p appendBytes:blend length:sizeof blend];
	[p appendBytes:&vl length:4];
	[p appendData:vn];
	[p appendData:fnn];
	if (rpc_call(15, p.bytes, (uint32_t)p.length, &rid, NULL, 0, NULL) != 0) {
		if (error) {
			*error = [NSError errorWithDomain:@"MTLLibraryErrorDomain" code:3 userInfo:nil];
		}
		return nil;
	}
	MSRenderPipeline *r = [[MSRenderPipeline alloc] init];

	r.rid = rid;
	return r;
}
- (BOOL)isLowPower { return NO; }
- (BOOL)isHeadless { return NO; }
- (BOOL)isRemovable { return NO; }
- (BOOL)hasUnifiedMemory { return YES; }
- (uint64_t)registryID { return 0x50495845; }
- (NSUInteger)maxThreadsPerThreadgroupCount { return 1024; }
@end

@implementation MSLibrary
- (NSString *)label { return nil; }
- (void)setLabel:(NSString *)l {}
- (id<MTLDevice>)device { return nil; }
- (id<MTLFunction>)newFunctionWithName:(NSString *)name
{
	MSFunction *f = [[MSFunction alloc] init];

	f.lib = self;
	f.fname = name;
	return f;
}
@end

@implementation MSFunction
- (NSString *)name { return self.fname; }
- (NSString *)label { return nil; }
- (void)setLabel:(NSString *)l {}
- (id<MTLDevice>)device { return nil; }
@end

@implementation MSPipeline
- (NSUInteger)maxTotalThreadsPerThreadgroup { return self.maxThreads; }
- (NSUInteger)threadExecutionWidth { return 32; }
- (NSString *)label { return nil; }
- (id<MTLDevice>)device { return nil; }
@end

@implementation MSBuffer
- (void)dealloc
{
	if (self.rid) {
		uint32_t a[2] = { 1, self.rid };

		(void)rpc_call(14, a, sizeof a, NULL, NULL, 0, NULL);
	}
	free(self.mem);
	[super dealloc];
}
- (void *)contents { return self.mem; }
- (NSUInteger)length { return self.len; }
- (void)didModifyRange:(NSRange)range {}
- (NSString *)label { return nil; }
- (void)setLabel:(NSString *)l {}
- (id<MTLDevice>)device { return nil; }
@end

@implementation MSQueue
- (id<MTLCommandBuffer>)commandBuffer
{
	MSCommandBuffer *c = [[MSCommandBuffer alloc] init];

	c.dispatches = [NSMutableArray array];
	return c;
}
- (NSString *)label { return nil; }
- (void)setLabel:(NSString *)l {}
- (id<MTLDevice>)device { return nil; }
@end

@interface MSBlitEncoder : NSObject <MTLBlitCommandEncoder>
@property (nonatomic, assign) MSCommandBuffer *cb;
@end
@implementation MSBlitEncoder
- (void)generateMipmapsForTexture:(id<MTLTexture>)texture
{
	[self.cb.dispatches addObject:@{ @"type": @"mips", @"tex": texture }];
}
- (void)queue:(void (^)(void))blk
{
	[self.cb.dispatches addObject:@{ @"type": @"blk", @"blk": [[blk copy] autorelease] }];
}
- (void)copyFromBuffer:(id<MTLBuffer>)sb sourceOffset:(NSUInteger)so sourceBytesPerRow:(NSUInteger)bpr sourceBytesPerImage:(NSUInteger)bpi
	    sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dt destinationSlice:(NSUInteger)slice destinationLevel:(NSUInteger)level
	    destinationOrigin:(MTLOrigin)origin
{
	[self queue:^{
		MTLRegion r = MTLRegionMake2D(origin.x, origin.y, size.width, size.height);

		[dt replaceRegion:r mipmapLevel:level withBytes:(const uint8_t *)[sb contents] + so bytesPerRow:bpr];
	}];
}
- (void)copyFromBuffer:(id<MTLBuffer>)sb sourceOffset:(NSUInteger)so sourceBytesPerRow:(NSUInteger)bpr sourceBytesPerImage:(NSUInteger)bpi
	    sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dt destinationSlice:(NSUInteger)slice destinationLevel:(NSUInteger)level
	    destinationOrigin:(MTLOrigin)origin options:(MTLBlitOption)options
{
	[self copyFromBuffer:sb sourceOffset:so sourceBytesPerRow:bpr sourceBytesPerImage:bpi sourceSize:size toTexture:dt destinationSlice:slice
	    destinationLevel:level destinationOrigin:origin];
}
- (void)copyFromTexture:(id<MTLTexture>)st sourceSlice:(NSUInteger)slice sourceLevel:(NSUInteger)level sourceOrigin:(MTLOrigin)origin sourceSize:(MTLSize)size
	       toBuffer:(id<MTLBuffer>)db destinationOffset:(NSUInteger)doff destinationBytesPerRow:(NSUInteger)bpr destinationBytesPerImage:(NSUInteger)bpi
{
	[self queue:^{
		MTLRegion r = MTLRegionMake2D(origin.x, origin.y, size.width, size.height);

		[st getBytes:(uint8_t *)[db contents] + doff bytesPerRow:bpr fromRegion:r mipmapLevel:level];
	}];
}
- (void)copyFromTexture:(id<MTLTexture>)st sourceSlice:(NSUInteger)slice sourceLevel:(NSUInteger)level sourceOrigin:(MTLOrigin)origin sourceSize:(MTLSize)size
	       toBuffer:(id<MTLBuffer>)db destinationOffset:(NSUInteger)doff destinationBytesPerRow:(NSUInteger)bpr destinationBytesPerImage:(NSUInteger)bpi
	       options:(MTLBlitOption)options
{
	[self copyFromTexture:st sourceSlice:slice sourceLevel:level sourceOrigin:origin sourceSize:size toBuffer:db destinationOffset:doff
	    destinationBytesPerRow:bpr destinationBytesPerImage:bpi];
}
- (void)copyFromTexture:(id<MTLTexture>)st sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)size
	      toTexture:(id<MTLTexture>)dt destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dorigin
{
	[self queue:^{
		NSMutableData *tmp = [NSMutableData dataWithLength:size.width * size.height * 4];

		[st getBytes:tmp.mutableBytes bytesPerRow:size.width * 4 fromRegion:MTLRegionMake2D(so.x, so.y, size.width, size.height) mipmapLevel:sl];
		[dt replaceRegion:MTLRegionMake2D(dorigin.x, dorigin.y, size.width, size.height) mipmapLevel:dl withBytes:tmp.bytes bytesPerRow:size.width * 4];
	}];
}
- (void)copyFromTexture:(id<MTLTexture>)st toTexture:(id<MTLTexture>)dt
{
	[self copyFromTexture:st sourceSlice:0 sourceLevel:0 sourceOrigin:(MTLOrigin){ 0, 0, 0 } sourceSize:(MTLSize){ st.width, st.height, 1 } toTexture:dt
	    destinationSlice:0 destinationLevel:0 destinationOrigin:(MTLOrigin){ 0, 0, 0 }];
}
- (void)copyFromBuffer:(id<MTLBuffer>)sb sourceOffset:(NSUInteger)so toBuffer:(id<MTLBuffer>)db destinationOffset:(NSUInteger)doff size:(NSUInteger)size
{
	[self queue:^{
		memmove((uint8_t *)[db contents] + doff, (const uint8_t *)[sb contents] + so, size);
	}];
}
- (void)fillBuffer:(id<MTLBuffer>)buffer range:(NSRange)range value:(uint8_t)value
{
	[self queue:^{
		memset((uint8_t *)[buffer contents] + range.location, value, range.length);
	}];
}
- (void)synchronizeResource:(id<MTLResource>)resource {}
- (void)endEncoding {}
- (void)setLabel:(NSString *)l {}
- (NSString *)label { return nil; }
- (id<MTLDevice>)device { return nil; }
@end

@implementation MSCommandBuffer
- (id<MTLBlitCommandEncoder>)blitCommandEncoder
{
	MSBlitEncoder *e = [[MSBlitEncoder alloc] init];

	e.cb = self;
	return e;
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoder
{
	MSComputeEncoder *e = [[MSComputeEncoder alloc] init];

	e.cb = self;
	e.bound = [NSMutableDictionary dictionary];
	return e;
}
- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)desc
{
	MSRenderEncoder *e = [[MSRenderEncoder alloc] init];
	MTLRenderPassColorAttachmentDescriptor *c = desc.colorAttachments[0];

	e.cb = self;
	e.target = (MSTexture *)c.texture;
	e->clear[0] = (float)c.clearColor.red;
	e->clear[1] = (float)c.clearColor.green;
	e->clear[2] = (float)c.clearColor.blue;
	e->clear[3] = (float)c.clearColor.alpha;
	e->load_clears = c.loadAction == MTLLoadActionClear;
	e.depth = (MSTexture *)desc.depthAttachment.texture;
	e.stex = (MSTexture *)desc.stencilAttachment.texture;
	e.rtex = (MSTexture *)c.resolveTexture;
	e.visbuf = desc.visibilityResultBuffer;
	e->tlevel = (uint32_t)c.level;
	e->tslice = (uint32_t)c.slice;
	e->clear_stencil = desc.stencilAttachment.clearStencil;
	e->stencil_load_clears = desc.stencilAttachment.loadAction == MTLLoadActionClear;
	if (!e.depth) {
		e.depth = e.stex;
	}
	e->clear_depth = desc.depthAttachment.clearDepth;
	e->depth_load_clears = desc.depthAttachment.loadAction == MTLLoadActionClear;
	e.ftex = [NSMutableDictionary dictionary];
	e.fbound = [NSMutableDictionary dictionary];
	e.fsamp = [NSMutableDictionary dictionary];
	e.vtex = [NSMutableDictionary dictionary];
	e.vsamp = [NSMutableDictionary dictionary];
	e.bound = [NSMutableDictionary dictionary];
	return e;
}
- (void)commit
{
	self.st = MTLCommandBufferStatusCompleted;
	for (NSDictionary *d_ in self.dispatches) {
		NSDictionary *d = d_;

		if ([d[@"type"] isEqual:@"blk"]) {
			void (^blk)(void) = d[@"blk"];

			blk();
			continue;
		}
		if ([d[@"type"] isEqual:@"mips"]) {
			uint32_t id = ((MSTexture *)d[@"tex"]).rid;

			if (rpc_call(18, &id, 4, NULL, NULL, 0, NULL) != 0) { /* GEN_MIPS */
				self.st = MTLCommandBufferStatusError;
			}
			continue;
		}
		if ([d[@"type"] isEqual:@"render"]) {
			NSDictionary *ind = [d[@"ind"] isKindOfClass:[NSDictionary class]] ? d[@"ind"] : nil;

			if (ind) {
				NSMutableDictionary *m = [[d mutableCopy] autorelease];
				const uint32_t *a = (const uint32_t *)((const uint8_t *)((MSBuffer *)ind[@"buf"]).mem + [ind[@"off"] unsignedIntegerValue]);

				if ([ind[@"indexed"] boolValue]) {
					m[@"count"] = @(a[0]);
					m[@"inst"] = @(a[1]);
					m[@"ioff"] = @([d[@"ioff"] unsignedIntegerValue] + a[2] * [ind[@"isz"] unsignedIntegerValue]);
					m[@"bvert"] = @((int32_t)a[3]);
					m[@"binst"] = @(a[4]);
				} else {
					m[@"count"] = @(a[0]);
					m[@"inst"] = @(a[1]);
					m[@"start"] = @(a[2]);
					m[@"binst"] = @(a[3]);
				}
				d = m;
			}
			MSRenderPipeline *rp = d[@"pso"];
			MSTexture *tex = d[@"tex"];
			NSDictionary *bound = d[@"bound"], *fbound = d[@"fbound"], *ftex = d[@"ftex"];
			NSArray *keys = [[bound allKeys] sortedArrayUsingSelector:@selector(compare:)];
			NSArray *fbkeys = [[fbound allKeys] sortedArrayUsingSelector:@selector(compare:)];
			NSArray *fkeys = [[ftex allKeys] sortedArrayUsingSelector:@selector(compare:)];
			MSBuffer *ib = d[@"ibuf"];
			NSDictionary *extra = d[@"extra"];
			MSTexture *dtex = [extra[@"dtex"] isKindOfClass:[MSTexture class]] ? extra[@"dtex"] : nil;
			NSMutableData *call = [NSMutableData data];
			uint32_t h0[2] = { rp.rid, tex.rid };
			float *cl = (float *)[d[@"clear"] bytes];
			uint32_t h1[4], h2[10] = { [d[@"load"] unsignedIntValue], (uint32_t)keys.count, [d[@"prim"] unsignedIntValue],
						   [d[@"start"] unsignedIntValue], [d[@"count"] unsignedIntValue], (uint32_t)fkeys.count,
						   (uint32_t)fbkeys.count, ib ? ib.rid : 0u, [d[@"ioff"] unsignedIntValue], [d[@"itype"] unsignedIntValue] };
			void (^upload)(MSBuffer *) = ^(MSBuffer *b) {
				uint32_t w[2] = { b.rid, 0 };
				NSMutableData *wd = [NSMutableData dataWithBytes:w length:8];

				[wd appendBytes:b.mem length:b.len];
				(void)rpc_call(3, wd.bytes, (uint32_t)wd.length, NULL, NULL, 0, NULL);
			};

			float cd = (float)[extra[@"cd"] doubleValue];
			uint32_t h3[6] = { dtex ? dtex.rid : 0u, [extra[@"ds"] unsignedIntValue], 0, [extra[@"cull"] unsignedIntValue],
					   [extra[@"wind"] unsignedIntValue], [extra[@"dload"] unsignedIntValue] };

			memcpy(&h3[2], &cd, 4);
			memcpy(h1, cl, 16);
			[call appendBytes:h0 length:8];
			[call appendBytes:h1 length:16];
			[call appendBytes:h2 length:40];
			[call appendBytes:h3 length:24];
			for (NSNumber *k in keys) {
				MSBuffer *b = bound[k][@"buf"];

				upload(b);
				uint32_t e[3] = { b.rid, (uint32_t)k.unsignedIntValue, (uint32_t)[bound[k][@"off"] unsignedIntValue] };

				[call appendBytes:e length:sizeof e];
			}
			for (NSNumber *k in fkeys) {
				uint32_t e[2] = { ((MSTexture *)ftex[k]).rid, (uint32_t)k.unsignedIntValue };

				[call appendBytes:e length:sizeof e];
			}
			for (NSNumber *k in fbkeys) {
				MSBuffer *b = fbound[k][@"buf"];

				upload(b);
				uint32_t e[3] = { b.rid, (uint32_t)k.unsignedIntValue, (uint32_t)[fbound[k][@"off"] unsignedIntValue] };

				[call appendBytes:e length:sizeof e];
			}
			NSDictionary *fsamp = d[@"fsamp"];
			NSArray *fskeys = [[fsamp allKeys] sortedArrayUsingSelector:@selector(compare:)];
			uint32_t nfs = (uint32_t)fskeys.count;

			[call appendBytes:&nfs length:4];
			for (NSNumber *k in fskeys) {
				uint32_t e[2] = { ((MSSampler *)fsamp[k]).rid, (uint32_t)k.unsignedIntValue };

				[call appendBytes:e length:sizeof e];
			}
			NSData *vpd = [extra[@"vp"] isKindOfClass:[NSData class]] ? extra[@"vp"] : nil, *scd = [extra[@"sc"] isKindOfClass:[NSData class]] ? extra[@"sc"] : nil;
			uint32_t hasvp = vpd ? 1 : 0, hassc = scd ? 1 : 0, zero6[6] = { 0 }, zero4[4] = { 0 };

			[call appendBytes:&hasvp length:4];
			[call appendBytes:vpd ? vpd.bytes : zero6 length:24];
			[call appendBytes:&hassc length:4];
			[call appendBytes:scd ? scd.bytes : zero4 length:16];
			NSDictionary *vt = extra[@"vtex"], *vs = extra[@"vsamp"];
			uint32_t nvt = (uint32_t)vt.count, nvs = (uint32_t)vs.count;

			[call appendBytes:&nvt length:4];
			for (NSNumber *k in [vt allKeys]) {
				uint32_t e[2] = { ((MSTexture *)vt[k]).rid, (uint32_t)k.unsignedIntValue };

				[call appendBytes:e length:sizeof e];
			}
			[call appendBytes:&nvs length:4];
			for (NSNumber *k in [vs allKeys]) {
				uint32_t e[2] = { ((MSSampler *)vs[k]).rid, (uint32_t)k.unsignedIntValue };

				[call appendBytes:e length:sizeof e];
			}
			NSArray *sr = extra[@"sref"];
			uint32_t stl[6] = { [extra[@"stex"] isKindOfClass:[MSTexture class]] ? 1u : 0u, [sr[0] unsignedIntValue], [sr[1] unsignedIntValue],
					    [sr[2] unsignedIntValue], [sr[3] unsignedIntValue],
					    [extra[@"rtex"] isKindOfClass:[MSTexture class]] ? ((MSTexture *)extra[@"rtex"]).rid : 0u };

			[call appendBytes:stl length:sizeof stl];
			uint32_t di[3] = { [d[@"inst"] unsignedIntValue] ? [d[@"inst"] unsignedIntValue] : 1u, [d[@"binst"] unsignedIntValue], [d[@"bvert"] unsignedIntValue] };

			[call appendBytes:di length:sizeof di];
			NSArray *vis = [d[@"vis"] isKindOfClass:[NSArray class]] ? d[@"vis"] : nil;
			uint32_t vw[3] = { vis ? ((MSBuffer *)vis[0]).rid : 0u, vis ? [vis[1] unsignedIntValue] : 0u, vis ? [vis[2] unsignedIntValue] : 0u };

			[call appendBytes:vw length:sizeof vw];
			uint32_t tls[2] = { [d[@"tl"] unsignedIntValue], [d[@"ts"] unsignedIntValue] };

			[call appendBytes:tls length:sizeof tls];
			if (ib) {
				upload(ib);
			}
			if (rpc_call(12, call.bytes, (uint32_t)call.length, NULL, NULL, 0, NULL) != 0) {
				self.st = MTLCommandBufferStatusError;
			}
			if (vis) {
				MSBuffer *vb = vis[0];
				uint32_t r[3] = { vb.rid, [vis[2] unsignedIntValue], 8 }, n = 0;
				uint64_t got = 0;

				if (rpc_call(4, r, sizeof r, NULL, &got, 8, &n) == 0 && n == 8) {
					uint64_t *dst = (uint64_t *)((uint8_t *)vb.mem + [vis[2] unsignedIntValue]);

					*dst = [vis[3] boolValue] ? got : *dst + got;
					if ([vis[1] unsignedIntValue] == 1) {
						*dst = *dst ? 1 : 0;
					}
				}
			}
			continue;
		}
		MSPipeline *pso = d[@"pso"];
		NSDictionary *bound = d[@"bound"];
		NSArray *keys = [[bound allKeys] sortedArrayUsingSelector:@selector(compare:)];
		NSMutableData *call = [NSMutableData data];
		uint32_t hdr[8] = { pso.rid, (uint32_t)keys.count };
		MTLSize grid, tg;

		[d[@"gridv"] getValue:&grid];
		[d[@"tgv"] getValue:&tg];
		hdr[2] = (uint32_t)grid.width; hdr[3] = (uint32_t)grid.height; hdr[4] = (uint32_t)grid.depth;
		hdr[5] = (uint32_t)tg.width; hdr[6] = (uint32_t)tg.height; hdr[7] = (uint32_t)tg.depth;
		[call appendBytes:hdr length:sizeof hdr];
		/* upload every bound buffer's host memory, then bind */
		for (NSNumber *k in keys) {
			NSDictionary *bd = bound[k];
			MSBuffer *b = bd[@"buf"];
			uint32_t w[2] = { b.rid, 0 };
			NSMutableData *wd = [NSMutableData dataWithBytes:w length:8];

			[wd appendBytes:b.mem length:b.len];
			(void)rpc_call(3, wd.bytes, (uint32_t)wd.length, NULL, NULL, 0, NULL);
			uint32_t e[3] = { b.rid, (uint32_t)k.unsignedIntValue, (uint32_t)[bd[@"off"] unsignedIntValue] };

			[call appendBytes:e length:sizeof e];
		}
		NSDictionary *ct = [d[@"ctex"] isKindOfClass:[NSDictionary class]] ? d[@"ctex"] : nil;
		NSDictionary *tm = [d[@"tgmem"] isKindOfClass:[NSDictionary class]] ? d[@"tgmem"] : nil;
		uint32_t nct = (uint32_t)ct.count, ntm = (uint32_t)tm.count;

		[call appendBytes:&nct length:4];
		for (NSNumber *k in [ct allKeys]) {
			uint32_t e[2] = { ((MSTexture *)ct[k]).rid, (uint32_t)k.unsignedIntValue };

			[call appendBytes:e length:sizeof e];
		}
		[call appendBytes:&ntm length:4];
		for (NSNumber *k in [tm allKeys]) {
			uint32_t e[2] = { (uint32_t)[tm[k] unsignedIntValue], (uint32_t)k.unsignedIntValue };

			[call appendBytes:e length:sizeof e];
		}
		if (rpc_call(6, call.bytes, (uint32_t)call.length, NULL, NULL, 0, NULL) != 0) {
			self.st = MTLCommandBufferStatusError;
			continue;
		}
		/* read every bound buffer back (the shader may have written any of them) */
		for (NSNumber *k in keys) {
			MSBuffer *b = bound[k][@"buf"];
			uint32_t r[3] = { b.rid, 0, (uint32_t)b.len }, n = 0;

			(void)rpc_call(4, r, sizeof r, NULL, b.mem, (uint32_t)b.len, &n);
		}
	}
	[self finishPresents];
}
- (void)finishPresents
{
	for (id<CAMetalDrawable> d in self.presents) {
		[d present];
	}
	[self.presents removeAllObjects];
	for (void (^h)(id<MTLCommandBuffer>) in self.handlers) {
		h(self);
	}
	[self.handlers removeAllObjects];
}
- (void)presentDrawable:(id<MTLDrawable>)drawable
{
	if (!self.presents) {
		self.presents = [NSMutableArray array];
	}
	[self.presents addObject:drawable];
}
- (void)presentDrawable:(id<MTLDrawable>)drawable atTime:(CFTimeInterval)t { [self presentDrawable:drawable]; }
- (void)presentDrawable:(id<MTLDrawable>)drawable afterMinimumDuration:(CFTimeInterval)t { [self presentDrawable:drawable]; }
- (void)addCompletedHandler:(void (^)(id<MTLCommandBuffer>))block
{
	if (!self.handlers) {
		self.handlers = [NSMutableArray array];
	}
	[self.handlers addObject:[[block copy] autorelease]];
}
- (void)addScheduledHandler:(void (^)(id<MTLCommandBuffer>))block { block(self); }
- (void)enqueue {}
- (void)waitUntilCompleted {}
- (void)waitUntilScheduled {}
- (MTLCommandBufferStatus)status { return self.st; }
- (NSString *)label { return nil; }
- (void)setLabel:(NSString *)l {}
- (id<MTLDevice>)device { return nil; }
- (id<MTLCommandQueue>)commandQueue { return nil; }
- (NSError *)error { return nil; }
@end

@implementation MSComputeEncoder
- (void)setComputePipelineState:(id<MTLComputePipelineState>)state { self.pso = (MSPipeline *)state; }
- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	self.bound[@(index)] = @{ @"buf": buffer, @"off": @(offset) };
}
- (void)setBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	NSDictionary *b = self.bound[@(index)];

	if (b) {
		self.bound[@(index)] = @{ @"buf": b[@"buf"], @"off": @(offset) };
	}
}
- (void)setBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index
{
	id<MTLBuffer> b = [MTLCreateSystemDefaultDevice() newBufferWithBytes:bytes length:length options:MTLResourceStorageModeShared];

	self.bound[@(index)] = @{ @"buf": b, @"off": @0 };
	[b release];
}
- (void)setTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index
{
	if (!self.ctex) {
		self.ctex = [NSMutableDictionary dictionary];
	}
	if (texture) {
		self.ctex[@(index)] = texture;
	} else {
		[self.ctex removeObjectForKey:@(index)];
	}
}
- (void)setThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index
{
	if (!self.tgmem) {
		self.tgmem = [NSMutableDictionary dictionary];
	}
	self.tgmem[@(index)] = @(length);
}
- (void)setSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {}
- (void)dispatchThreadgroupsWithIndirectBuffer:(id<MTLBuffer>)indirectBuffer indirectBufferOffset:(NSUInteger)offset threadsPerThreadgroup:(MTLSize)tg
{
	const uint32_t *a = (const uint32_t *)((const uint8_t *)[indirectBuffer contents] + offset);

	[self dispatchThreadgroups:(MTLSize){ a[0], a[1], a[2] } threadsPerThreadgroup:tg];
}
- (void)record:(MTLSize)grid group:(MTLSize)tg
{
	[self.cb.dispatches addObject:@{ @"pso": self.pso, @"bound": [self.bound copy],
					 @"ctex": self.ctex ? [[self.ctex copy] autorelease] : (id)[NSNull null],
					 @"tgmem": self.tgmem ? [[self.tgmem copy] autorelease] : (id)[NSNull null],
					 @"gridv": [NSValue valueWithBytes:&grid objCType:@encode(MTLSize)],
					 @"tgv": [NSValue valueWithBytes:&tg objCType:@encode(MTLSize)] }];
}
- (void)dispatchThreads:(MTLSize)threadsPerGrid threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup
{
	[self record:threadsPerGrid group:threadsPerThreadgroup];
}
- (void)dispatchThreadgroups:(MTLSize)groups threadsPerThreadgroup:(MTLSize)tg
{
	MTLSize total = { groups.width * tg.width, groups.height * tg.height, groups.depth * tg.depth };

	[self record:total group:tg];
}
- (void)endEncoding {}
- (NSString *)label { return nil; }
- (void)setLabel:(NSString *)l {}
- (id<MTLDevice>)device { return nil; }
@end

/* a mip level's texels, in bands of rows that fit the mailbox: any texture size */
static int
read_level_slice(uint32_t rid, uint32_t level, NSUInteger lw, NSUInteger lh, uint32_t slice, uint32_t zplane, uint8_t *dst)
{
	NSUInteger rows = (PAYLOAD_MAX - 64) / (lw * 4), y = 0;

	if (rows == 0) {
		return -1;
	}
	if (lw * lh * 4 <= PAYLOAD_MAX - 64) {
		uint32_t q[6] = { rid, level, 0, 0, slice, zplane }, n = 0;

		return rpc_call(10, q, 24, NULL, dst, (uint32_t)(lw * lh * 4), &n) == 0 && n == lw * lh * 4 ? 0 : -1;
	}
	while (y < lh) {
		NSUInteger k = lh - y < rows ? lh - y : rows;
		uint32_t q[6] = { rid, level, (uint32_t)y, (uint32_t)k, slice, zplane }, n = 0;

		if (rpc_call(10, q, 24, NULL, dst + y * lw * 4, (uint32_t)(k * lw * 4), &n) != 0 || n != k * lw * 4) {
			return -1;
		}
		y += k;
	}
	return 0;
}

static int
read_level(uint32_t rid, uint32_t level, NSUInteger lw, NSUInteger lh, uint8_t *dst)
{
	return read_level_slice(rid, level, lw, lh, 0, 0, dst);
}

@implementation MSTexture
- (void)dealloc
{
	if (self.rid) {
		uint32_t a[2] = { 2, self.rid };

		(void)rpc_call(14, a, sizeof a, NULL, NULL, 0, NULL);
	}
	[super dealloc];
}
- (NSUInteger)width { return self.w; }
- (NSUInteger)height { return self.h; }
- (NSUInteger)depth { return self.dep ? self.dep : 1; }
- (NSUInteger)arrayLength { return self.alen ? self.alen : 1; }
- (MTLPixelFormat)pixelFormat { return self.fmt ? self.fmt : MTLPixelFormatRGBA8Unorm; }
- (MTLTextureType)textureType { return self.samples > 1 ? MTLTextureType2DMultisample : (self.ttype ? (MTLTextureType)self.ttype : MTLTextureType2D); }
- (NSUInteger)sampleCount { return self.samples ? self.samples : 1; }
- (NSUInteger)mipmapLevelCount { return self.mips ? self.mips : 1; }
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice withBytes:(const void *)pixelBytes
	  bytesPerRow:(NSUInteger)bytesPerRow bytesPerImage:(NSUInteger)bytesPerImage
{
	/* RGBA8/BGRA8 texels of one array slice or cube face, or of the depth planes of a 3D texture, in bands that fit the RPC's payload */
	NSUInteger w = region.size.width, h = region.size.height, planes = region.size.depth ? region.size.depth : 1, rows = (PAYLOAD_MAX - 96) / (w * 4 ? w * 4 : 1);

	if (rows == 0) {
		return;
	}
	for (NSUInteger pl = 0; pl < planes; pl++) {
		for (NSUInteger y = 0; y < h; y += rows) {
			NSUInteger k = h - y < rows ? h - y : rows;
			uint32_t hdr[8] = { self.rid, (uint32_t)region.origin.x, (uint32_t)(region.origin.y + y), (uint32_t)w, (uint32_t)k, (uint32_t)level, (uint32_t)slice,
					    (uint32_t)(region.origin.z + pl) };
			NSMutableData *m = [NSMutableData dataWithBytes:hdr length:sizeof hdr];

			for (NSUInteger r = 0; r < k; r++) {
				[m appendBytes:(const uint8_t *)pixelBytes + pl * bytesPerImage + (y + r) * bytesPerRow length:w * 4];
				if (self.fmt == MTLPixelFormatBGRA8Unorm) {
					uint8_t *q = (uint8_t *)m.mutableBytes + m.length - w * 4;

					for (NSUInteger i = 0; i < w; i++) {
						uint8_t t = q[i * 4];

						q[i * 4] = q[i * 4 + 2];
						q[i * 4 + 2] = t;
					}
				}
			}
			(void)rpc_call(13, m.bytes, (uint32_t)m.length, NULL, NULL, 0, NULL);
		}
	}
}
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level withBytes:(const void *)pixelBytes bytesPerRow:(NSUInteger)bytesPerRow
{
	[self replaceRegion:region mipmapLevel:level slice:0 withBytes:pixelBytes bytesPerRow:bytesPerRow bytesPerImage:0];
}
- (void)getBytes:(void *)pixelBytes bytesPerRow:(NSUInteger)bytesPerRow bytesPerImage:(NSUInteger)bytesPerImage fromRegion:(MTLRegion)region
     mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice
{
	NSUInteger lw = self.w >> level ? self.w >> level : 1, lh = self.h >> level ? self.h >> level : 1, planes = region.size.depth ? region.size.depth : 1;
	uint8_t *all = malloc(lw * lh * 4);

	for (NSUInteger pl = 0; pl < planes; pl++) {
		if (read_level_slice(self.rid, (uint32_t)level, lw, lh, (uint32_t)slice, (uint32_t)(region.origin.z + pl), all) != 0) {
			break;
		}
		for (NSUInteger y = 0; y < region.size.height; y++) {
			uint8_t *q = (uint8_t *)pixelBytes + pl * bytesPerImage + y * bytesPerRow;

			memcpy(q, all + ((region.origin.y + y) * lw + region.origin.x) * 4, region.size.width * 4);
			if (self.fmt == MTLPixelFormatBGRA8Unorm) {
				for (NSUInteger i = 0; i < region.size.width; i++) {
					uint8_t t = q[i * 4];

					q[i * 4] = q[i * 4 + 2];
					q[i * 4 + 2] = t;
				}
			}
		}
	}
	free(all);
}
- (void)getBytes:(void *)pixelBytes bytesPerRow:(NSUInteger)bytesPerRow fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level
{
	[self getBytes:pixelBytes bytesPerRow:bytesPerRow bytesPerImage:0 fromRegion:region mipmapLevel:level slice:0];
}
- (NSString *)label { return nil; }
- (void)setLabel:(NSString *)l {}
- (id<MTLDevice>)device { return nil; }
@end

@implementation MSRenderPipeline
- (NSString *)label { return nil; }
- (id<MTLDevice>)device { return nil; }
@end

@implementation MSRenderEncoder
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)pipelineState { self.pso = (MSRenderPipeline *)pipelineState; }
- (void)setVertexBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	self.bound[@(index)] = @{ @"buf": buffer, @"off": @(offset) };
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType vertexStart:(NSUInteger)vertexStart vertexCount:(NSUInteger)vertexCount
{
	[self.cb.dispatches addObject:@{ @"type": @"render", @"pso": self.pso, @"tex": self.target, @"bound": [self.bound copy],
					 @"clear": [NSData dataWithBytes:clear length:16], @"prim": @((uint32_t)primitiveType),
					 @"start": @(vertexStart), @"count": @(vertexCount), @"load": @((load_clears && drawn == 0) ? 0u : 1u),
					 @"ftex": [self.ftex copy], @"fbound": [self.fbound copy], @"fsamp": [self.fsamp copy], @"extra": [self extraState],
					 @"inst": @(pend_inst ? pend_inst : 1u), @"binst": @(pend_binst), @"bvert": @(pend_bvert),
					 @"ind": pend_ind ? (id)pend_ind : (id)[NSNull null],
					 @"tl": @(tlevel), @"ts": @(tslice),
					 @"vis": (vis_mode && self.visbuf) ? (id)@[ self.visbuf, @(vis_mode), @(vis_off), @(vis_first) ] : (id)[NSNull null] }];
	vis_first = NO;
	pend_ind = nil;
	pend_inst = pend_binst = 0;
	pend_bvert = 0;
	drawn++;
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType vertexStart:(NSUInteger)vertexStart vertexCount:(NSUInteger)vertexCount instanceCount:(NSUInteger)instanceCount
{
	pend_inst = (uint32_t)instanceCount;
	[self drawPrimitives:primitiveType vertexStart:vertexStart vertexCount:vertexCount];
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType vertexStart:(NSUInteger)vertexStart vertexCount:(NSUInteger)vertexCount instanceCount:(NSUInteger)instanceCount
	  baseInstance:(NSUInteger)baseInstance
{
	pend_binst = (uint32_t)baseInstance;
	[self drawPrimitives:primitiveType vertexStart:vertexStart vertexCount:vertexCount instanceCount:instanceCount];
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType indirectBuffer:(id<MTLBuffer>)indirectBuffer indirectBufferOffset:(NSUInteger)offset
{
	/* MTLDrawPrimitivesIndirectArguments: vertexCount, instanceCount, vertexStart, baseInstance: read from the host copy when the command buffer runs, so
	 * arguments a compute pass wrote earlier in it count */
	pend_ind = @{ @"buf": indirectBuffer, @"off": @(offset), @"indexed": @NO, @"isz": @0 };
	[self drawPrimitives:primitiveType vertexStart:0 vertexCount:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType
		  indexBuffer:(id<MTLBuffer>)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset
{
	[self.cb.dispatches addObject:@{ @"type": @"render", @"pso": self.pso, @"tex": self.target, @"bound": [self.bound copy],
					 @"clear": [NSData dataWithBytes:clear length:16], @"prim": @((uint32_t)primitiveType), @"start": @0,
					 @"count": @(indexCount), @"load": @((load_clears && drawn == 0) ? 0u : 1u), @"ftex": [self.ftex copy],
					 @"fbound": [self.fbound copy], @"fsamp": [self.fsamp copy], @"extra": [self extraState], @"ibuf": indexBuffer, @"ioff": @(indexBufferOffset), @"itype": @((uint32_t)indexType),
					 @"inst": @(pend_inst ? pend_inst : 1u), @"binst": @(pend_binst), @"bvert": @(pend_bvert),
					 @"ind": pend_ind ? (id)pend_ind : (id)[NSNull null],
					 @"tl": @(tlevel), @"ts": @(tslice),
					 @"vis": (vis_mode && self.visbuf) ? (id)@[ self.visbuf, @(vis_mode), @(vis_off), @(vis_first) ] : (id)[NSNull null] }];
	vis_first = NO;
	pend_ind = nil;
	pend_inst = pend_binst = 0;
	pend_bvert = 0;
	drawn++;
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType
		  indexBuffer:(id<MTLBuffer>)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset instanceCount:(NSUInteger)instanceCount
{
	pend_inst = (uint32_t)instanceCount;
	[self drawIndexedPrimitives:primitiveType indexCount:indexCount indexType:indexType indexBuffer:indexBuffer indexBufferOffset:indexBufferOffset];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType
		  indexBuffer:(id<MTLBuffer>)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset instanceCount:(NSUInteger)instanceCount
		   baseVertex:(NSInteger)baseVertex baseInstance:(NSUInteger)baseInstance
{
	pend_bvert = (int32_t)baseVertex;
	pend_binst = (uint32_t)baseInstance;
	[self drawIndexedPrimitives:primitiveType indexCount:indexCount indexType:indexType indexBuffer:indexBuffer indexBufferOffset:indexBufferOffset
		      instanceCount:instanceCount];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)indexBuffer
	    indexBufferOffset:(NSUInteger)indexBufferOffset indirectBuffer:(id<MTLBuffer>)indirectBuffer indirectBufferOffset:(NSUInteger)offset
{
	/* MTLDrawIndexedPrimitivesIndirectArguments: indexCount, instanceCount, indexStart, baseVertex (i32), baseInstance (read when the buffer runs) */
	pend_ind = @{ @"buf": indirectBuffer, @"off": @(offset), @"indexed": @YES, @"isz": @(indexType == MTLIndexTypeUInt32 ? 4 : 2) };
	[self drawIndexedPrimitives:primitiveType indexCount:0 indexType:indexType indexBuffer:indexBuffer indexBufferOffset:indexBufferOffset];
}
- (void)setVertexBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index
{
	id<MTLBuffer> b = [MTLCreateSystemDefaultDevice() newBufferWithBytes:bytes length:length options:MTLResourceStorageModeShared];

	self.bound[@(index)] = @{ @"buf": b, @"off": @0 };
	[b release];
}
- (void)setFragmentBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index
{
	id<MTLBuffer> b = [MTLCreateSystemDefaultDevice() newBufferWithBytes:bytes length:length options:MTLResourceStorageModeShared];

	self.fbound[@(index)] = @{ @"buf": b, @"off": @0 };
	[b release];
}
- (void)setFragmentBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	if (buffer) {
		self.fbound[@(index)] = @{ @"buf": buffer, @"off": @(offset) };
	} else {
		[self.fbound removeObjectForKey:@(index)];
	}
}
- (void)setFragmentTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index
{
	if (texture) {
		self.ftex[@(index)] = texture;
	} else {
		[self.ftex removeObjectForKey:@(index)];
	}
}
- (void)setVertexTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index
{
	if (texture) {
		self.vtex[@(index)] = texture;
	} else {
		[self.vtex removeObjectForKey:@(index)];
	}
}
- (void)setVertexSamplerState:(id)sampler atIndex:(NSUInteger)index
{
	if (sampler) {
		self.vsamp[@(index)] = sampler;
	} else {
		[self.vsamp removeObjectForKey:@(index)];
	}
}
- (void)setFragmentSamplerState:(id)sampler atIndex:(NSUInteger)index
{
	if (sampler) {
		self.fsamp[@(index)] = sampler;
	} else {
		[self.fsamp removeObjectForKey:@(index)];
	}
}
- (void)setFragmentSamplerState:(id)sampler lodMinClamp:(float)lmin lodMaxClamp:(float)lmax atIndex:(NSUInteger)index
{
	[self setFragmentSamplerState:sampler atIndex:index];
}
- (void)setViewport:(MTLViewport)v
{
	float f[6] = { (float)v.originX, (float)v.originY, (float)v.width, (float)v.height, (float)v.znear, (float)v.zfar };

	self.vpdata = [NSData dataWithBytes:f length:sizeof f];
}
- (void)setScissorRect:(MTLScissorRect)r
{
	uint32_t u[4] = { (uint32_t)r.x, (uint32_t)r.y, (uint32_t)r.width, (uint32_t)r.height };

	self.scdata = [NSData dataWithBytes:u length:sizeof u];
}
- (void)setCullMode:(MTLCullMode)mode { cull = (uint32_t)mode; }
- (void)setFrontFacingWinding:(MTLWinding)w { winding = (uint32_t)w; }
- (void)setVisibilityResultMode:(MTLVisibilityResultMode)mode offset:(NSUInteger)offset
{
	vis_mode = (uint32_t)mode;
	vis_off = (uint32_t)offset;
	vis_first = YES; /* pend_vis: the next draw opens a new result */
}
- (void)setStencilReferenceValue:(uint32_t)value
{
	sref_f = sref_b = value;
}
- (void)setStencilFrontReferenceValue:(uint32_t)front backReferenceValue:(uint32_t)back
{
	sref_f = front;
	sref_b = back;
}
- (void)setDepthStencilState:(id<MTLDepthStencilState>)state { dsid = [(MSDepthStencilState *)state rid]; }
- (NSDictionary *)extraState
{
	return @{ @"dtex": self.depth ? (id)self.depth : (id)[NSNull null], @"ds": @(dsid), @"cd": @(clear_depth),
		  @"vtex": [self.vtex copy], @"vsamp": [self.vsamp copy], @"stex": self.stex ? (id)self.stex : (id)[NSNull null], @"rtex": self.rtex ? (id)self.rtex : (id)[NSNull null], @"sref": @[ @(sref_f), @(sref_b), @(clear_stencil), @((stencil_load_clears && drawn == 0) ? 0u : 1u) ], @"vp": self.vpdata ? (id)self.vpdata : (id)[NSNull null], @"sc": self.scdata ? (id)self.scdata : (id)[NSNull null], @"dload": @((depth_load_clears && drawn == 0) ? 0u : 1u), @"cull": @(cull), @"wind": @(winding) };
}
- (void)endEncoding {}
- (NSString *)label { return nil; }
- (void)setLabel:(NSString *)l {}
- (id<MTLDevice>)device { return nil; }
@end


/* ------------------------------------------------------------------------------------------------ descriptors
 * The public descriptor classes, implemented here so that a program linked with this library alone needs no Metal.framework.
 * Only the properties a simple render program uses are implemented. */

@implementation MTLTextureDescriptor
@synthesize pixelFormat, width, height, usage, mipmapLevelCount, textureType, sampleCount, depth, arrayLength;
+ (MTLTextureDescriptor *)textureCubeDescriptorWithPixelFormat:(MTLPixelFormat)pf size:(NSUInteger)size mipmapped:(BOOL)m
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:size height:size mipmapped:m];

	d.textureType = MTLTextureTypeCube; /* cubeDescriptor */
	return d;
}
+ (MTLTextureDescriptor *)texture2DDescriptorWithPixelFormat:(MTLPixelFormat)pf width:(NSUInteger)w height:(NSUInteger)h mipmapped:(BOOL)m
{
	MTLTextureDescriptor *d = [[MTLTextureDescriptor alloc] init];

	d.pixelFormat = pf;
	d.width = w;
	d.height = h;
	d.mipmapLevelCount = 1;
	d.sampleCount = 1;
	d.depth = 1;
	d.arrayLength = 1;
	d.textureType = MTLTextureType2D;
	if (m) {
		NSUInteger n = 1, side = w > h ? w : h;

		while (side > 1) {
			side >>= 1;
			n++;
		}
		d.mipmapLevelCount = n;
	}
	return d;
}
@end

@implementation MTLRenderPipelineColorAttachmentDescriptor
@synthesize pixelFormat, blendingEnabled, sourceRGBBlendFactor, destinationRGBBlendFactor, rgbBlendOperation, sourceAlphaBlendFactor;
@synthesize destinationAlphaBlendFactor, alphaBlendOperation, writeMask;
- (instancetype)init
{
	if ((self = [super init])) {
		sourceRGBBlendFactor = sourceAlphaBlendFactor = MTLBlendFactorOne;
		destinationRGBBlendFactor = destinationAlphaBlendFactor = MTLBlendFactorZero;
		writeMask = MTLColorWriteMaskAll;
	}
	return self;
}
@end

@implementation MTLRenderPipelineColorAttachmentDescriptorArray {
	NSMutableDictionary *items;
}
- (id)objectAtIndexedSubscript:(NSUInteger)i
{
	if (!items) {
		items = [[NSMutableDictionary alloc] init];
	}
	id o = items[@(i)];

	if (!o) {
		o = [[MTLRenderPipelineColorAttachmentDescriptor alloc] init];
		items[@(i)] = o;
	}
	return o;
}
@end

@implementation MTLRenderPipelineDescriptor {
	MTLRenderPipelineColorAttachmentDescriptorArray *colors;
}
@synthesize vertexFunction, fragmentFunction, depthAttachmentPixelFormat, stencilAttachmentPixelFormat, sampleCount, rasterSampleCount;
- (MTLRenderPipelineColorAttachmentDescriptorArray *)colorAttachments
{
	if (!colors) {
		colors = [[MTLRenderPipelineColorAttachmentDescriptorArray alloc] init];
	}
	return colors;
}
@end

@implementation MTLRenderPassAttachmentDescriptor
@synthesize texture, loadAction, storeAction, resolveTexture, level, slice, depthPlane, resolveLevel, resolveSlice, resolveDepthPlane;
@end

@implementation MTLRenderPassColorAttachmentDescriptor
@synthesize clearColor;
@end

@implementation MTLRenderPassColorAttachmentDescriptorArray {
	NSMutableDictionary *items;
}
- (id)objectAtIndexedSubscript:(NSUInteger)i
{
	if (!items) {
		items = [[NSMutableDictionary alloc] init];
	}
	id o = items[@(i)];

	if (!o) {
		o = [[MTLRenderPassColorAttachmentDescriptor alloc] init];
		items[@(i)] = o;
	}
	return o;
}
@end

@implementation MTLSamplerDescriptor
@synthesize minFilter, magFilter, mipFilter, sAddressMode, tAddressMode, rAddressMode, borderColor, normalizedCoordinates, lodMinClamp, lodMaxClamp,
    maxAnisotropy, compareFunction, supportArgumentBuffers, label;
- (instancetype)init
{
	if ((self = [super init])) {
		maxAnisotropy = 1;
		normalizedCoordinates = YES;
		lodMaxClamp = 3.4028234663852886e38f;
	}
	return self;
}
@end

@implementation MTLStencilDescriptor
@synthesize stencilCompareFunction, stencilFailureOperation, depthFailureOperation, depthStencilPassOperation, readMask, writeMask;
- (instancetype)init
{
	if ((self = [super init])) {
		stencilCompareFunction = MTLCompareFunctionAlways;
		readMask = writeMask = 0xffffffff;
	}
	return self;
}
- (id)copyWithZone:(NSZone *)zone
{
	MTLStencilDescriptor *c = [[MTLStencilDescriptor allocWithZone:zone] init];

	c.stencilCompareFunction = stencilCompareFunction;
	c.stencilFailureOperation = stencilFailureOperation;
	c.depthFailureOperation = depthFailureOperation;
	c.depthStencilPassOperation = depthStencilPassOperation;
	c.readMask = readMask;
	c.writeMask = writeMask;
	return c;
}
@end

@implementation MTLRenderPassStencilAttachmentDescriptor
@synthesize clearStencil, stencilResolveFilter;
@end

@implementation MTLDepthStencilDescriptor
@synthesize depthCompareFunction, depthWriteEnabled, frontFaceStencil, backFaceStencil, label;
- (instancetype)init
{
	if ((self = [super init])) {
		depthCompareFunction = MTLCompareFunctionAlways;
	}
	return self;
}
@end

@implementation MTLRenderPassDepthAttachmentDescriptor
@synthesize clearDepth, depthResolveFilter;
- (instancetype)init
{
	if ((self = [super init])) {
		clearDepth = 1.0;
	}
	return self;
}
@end

@implementation MTLRenderPassDescriptor {
	id<MTLBuffer> visBuf;
	MTLRenderPassColorAttachmentDescriptorArray *colors;
	MTLRenderPassDepthAttachmentDescriptor *depth;
	MTLRenderPassStencilAttachmentDescriptor *stencil;
}
- (id<MTLBuffer>)visibilityResultBuffer { return visBuf; }
- (void)setVisibilityResultBuffer:(id<MTLBuffer>)b
{
	[b retain];
	[visBuf release];
	visBuf = b;
}
- (MTLRenderPassStencilAttachmentDescriptor *)stencilAttachment
{
	if (!stencil) {
		stencil = [[MTLRenderPassStencilAttachmentDescriptor alloc] init];
	}
	return stencil;
}
- (MTLRenderPassDepthAttachmentDescriptor *)depthAttachment
{
	if (!depth) {
		depth = [[MTLRenderPassDepthAttachmentDescriptor alloc] init];
	}
	return depth;
}
+ (MTLRenderPassDescriptor *)renderPassDescriptor
{
	return [[MTLRenderPassDescriptor alloc] init];
}
- (MTLRenderPassColorAttachmentDescriptorArray *)colorAttachments
{
	if (!colors) {
		colors = [[MTLRenderPassColorAttachmentDescriptorArray alloc] init];
	}
	return colors;
}
@end

/* ------------------------------------------------------------------------------------------------ CAMetalLayer */

static const char *kDeviceKey = "ms.device";
static const char *kPoolKey = "ms.pool";
static const char *kCursorKey = "ms.cursor";

@implementation MSDrawable
- (id<MTLTexture>)texture { return self.tex; }
- (CAMetalLayer *)layer { return self.lay; }
- (NSUInteger)drawableID { return self.did; }
- (CFTimeInterval)presentedTime { return 0; }
- (void)addPresentedHandler:(void (^)(id<MTLDrawable>))block { block(self); }
- (void)present
{
	MSTexture *t = self.tex;
	NSUInteger w = t.w, h = t.h;
	uint32_t tid = t.rid, n = 0;
	uint8_t *px = malloc(w * h * 4);

	n = (uint32_t)(w * h * 4);
	if (read_level(tid, 0, w, h, px) == 0) {
		CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
		CFDataRef data = CFDataCreate(NULL, px, (CFIndex)n);
		CGDataProviderRef dp = CGDataProviderCreateWithCFData(data);
		CGImageRef img = CGImageCreate(w, h, 8, 32, w * 4, cs, kCGBitmapByteOrderDefault | kCGImageAlphaPremultipliedLast, dp, NULL, false,
		    kCGRenderingIntentDefault);
		CAMetalLayer *layer = [self.lay retain];

		dispatch_async(dispatch_get_main_queue(), ^{
			[CATransaction begin];
			[CATransaction setDisableActions:YES];
			layer.contents = (id)img;
			[CATransaction commit];
			CGImageRelease(img);
			[layer release];
		});
		CGDataProviderRelease(dp);
		CFRelease(data);
		CGColorSpaceRelease(cs);
	}
	free(px);
}
- (void)presentAtTime:(CFTimeInterval)t { [self present]; }
- (void)presentAfterMinimumDuration:(CFTimeInterval)t { [self present]; }
@end

static id
ms_layer_nextDrawable(id self, SEL _cmd)
{
	CAMetalLayer *l = self;
	CGSize size = l.drawableSize;

	if (size.width < 1 || size.height < 1) {
		CGFloat scale = l.contentsScale > 0 ? l.contentsScale : 1;

		size = CGSizeMake(l.bounds.size.width * scale, l.bounds.size.height * scale);
	}
	NSUInteger w = (NSUInteger)size.width, h = (NSUInteger)size.height;
	NSMutableArray *pool = objc_getAssociatedObject(l, kPoolKey);
	id<MTLDevice> dev = MTLCreateSystemDefaultDevice();

	if (!dev || w < 1 || h < 1) {
		return nil;
	}
	if (!pool || [(MSTexture *)pool.firstObject w] != w || [(MSTexture *)pool.firstObject h] != h) {
		pool = [NSMutableArray array];
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:l.pixelFormat == MTLPixelFormatBGRA8Unorm ? MTLPixelFormatBGRA8Unorm : MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];

		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		for (int i = 0; i < 3; i++) {
			id<MTLTexture> t = [dev newTextureWithDescriptor:td];

			if (t) {
				[pool addObject:t];
			}
		}
		objc_setAssociatedObject(l, kPoolKey, pool, OBJC_ASSOCIATION_RETAIN);
	}
	if (pool.count == 0) {
		return nil;
	}
	NSUInteger cursor = [objc_getAssociatedObject(l, kCursorKey) unsignedIntegerValue];
	MSDrawable *d = [[[MSDrawable alloc] init] autorelease];

	d.tex = pool[cursor % pool.count];
	d.lay = l;
	d.did = cursor;
	objc_setAssociatedObject(l, kCursorKey, @(cursor + 1), OBJC_ASSOCIATION_RETAIN);
	return d;
}

static void
ms_layer_setDevice(id self, SEL _cmd, id device)
{
	objc_setAssociatedObject(self, kDeviceKey, device, OBJC_ASSOCIATION_RETAIN);
}

static id
ms_layer_device(id self, SEL _cmd)
{
	return objc_getAssociatedObject(self, kDeviceKey);
}

static void
ms_install_layer_support(void)
{
	Class c = NSClassFromString(@"CAMetalLayer");

	if (!c) {
		return;
	}
	class_replaceMethod(c, @selector(nextDrawable), (IMP)ms_layer_nextDrawable, "@@:");
	class_replaceMethod(c, @selector(setDevice:), (IMP)ms_layer_setDevice, "v@:@");
	class_replaceMethod(c, @selector(device), (IMP)ms_layer_device, "@@:");
	class_replaceMethod(c, NSSelectorFromString(@"preferredDevice"), (IMP)ms_layer_device, "@@:");
}

/* ------------------------------------------------------------------------------------------------ entry points */


/* Present a rendered texture on the panel: the server leaves its pixels in the ring and XNU pastes them into the scan-out
 * pages at (x, y) (cubs_present=1). The stand-in for presenting a CAMetalLayer drawable. */
void
MSPresentTexture(id<MTLTexture> texture, int x, int y)
{
	uint32_t p[3] = { ((MSTexture *)texture).rid, (uint32_t)x, (uint32_t)y };

	(void)rpc_call(11, p, sizeof p, NULL, NULL, 0, NULL);
}

id<MTLDevice>
MTLCreateSystemDefaultDevice(void)
{
	static id<MTLDevice> dev;
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		g_lock = [[NSLock alloc] init];
		if (rpc_open()) {
			dev = [[MSDevice alloc] init];
			ms_install_layer_support();
		}
	});
	return dev;
}

NSArray<id<MTLDevice>> *
MTLCopyAllDevices(void)
{
	id<MTLDevice> d = MTLCreateSystemDefaultDevice();

	return d ? [NSArray arrayWithObject:d] : [NSArray array];
}
