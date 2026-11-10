/*
 * camprobe: why is Camera.app's viewfinder black? A foreground app (com.cubs.camprobe, baked into /Applications, signed with camprobe.entitlements:
 * camera access by TCC) that shows two things at once:
 *   top half:    an AVCaptureVideoPreviewLayer on the session (what Camera.app uses)
 *   bottom half: the frames of an AVCaptureVideoDataOutput on the same session, turned into a UIImage with CoreImage (software)
 * and logs (to /tmp/camprobe.log; NSLog does not reach the kernel log for apps): the authorization, the session's state, interruptions and
 * errors, the frame format/size and, for some frames, what is in the pixels (average/maximum of the first plane), so that "no frames", "frames
 * of zeros", "frames with the picture but a black preview layer" can be told apart. The screenshot ring shows what really reaches the panel.
 *   xnu-clang -arch arm64 -isysroot $THEOS/sdks/iPhoneOS16.5.sdk -fno-objc-arc -O1 -Wno-deprecated-declarations -framework Foundation -framework UIKit \
 *       -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework CoreImage -framework QuartzCore -o CamProbe camprobe.m
 */
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <IOSurface/IOSurfaceRef.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void
L(NSString *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];

	va_end(ap);
	NSLog(@"camprobe: %@", s);
	FILE *f = fopen("/tmp/camprobe.log", "a");

	if (f != NULL) {
		fprintf(f, "camprobe: %s\n", [s UTF8String]);
		fclose(f);
	}
}

/* what the authorization question goes through here: the methods of the capture classes with "uthoriz" in their names, and TCC's own function */
static void
dump_authorization(void)
{
	const char *names[] = { "AVCaptureDevice", "AVCaptureDeviceInput", "AVCaptureSession" };

	for (int i = 0; i < 3; i++) {
		Class c = objc_getClass(names[i]);

		for (int meta = 0; meta < 2; meta++) {
			unsigned n = 0;
			Method *m = class_copyMethodList(meta ? object_getClass(c) : c, &n);

			for (unsigned k = 0; k < n; k++) {
				const char *sel = sel_getName(method_getName(m[k]));

				if (strcasestr(sel, "uthoriz") != NULL) {
					L(@"%s%s %s", meta ? "+" : "-", names[i], sel);
				}
			}
			free(m);
		}
	}
	void *f = dlsym(RTLD_DEFAULT, "TCCAccessPreflight");
	Dl_info info;

	L(@"TCCAccessPreflight at %p (%s)", f, f != NULL && dladdr(f, &info) != 0 ? info.dli_fname : "-");
	if (f != NULL) {
		int r = ((int (*)(CFStringRef, CFDictionaryRef))f)(CFSTR("kTCCServiceCamera"), NULL);

		L(@"TCCAccessPreflight(camera) = %d", r);
	}
}

static NSInteger
fake_status(id self, SEL _cmd, NSString *type)
{
	return 3; /* AVAuthorizationStatusAuthorized */
}

static void
fake_request(id self, SEL _cmd, NSString *type, void (^handler)(BOOL))
{
	if (handler != nil) {
		handler(YES);
	}
}

@interface CPApp : UIResponder <UIApplicationDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, retain) UIWindow *window;
@property (nonatomic, retain) AVCaptureSession *session;
@property (nonatomic, retain) AVCaptureVideoPreviewLayer *preview;
@property (nonatomic, retain) UIImageView *imageView;
@end

@implementation CPApp {
	int _frames;
}

- (void)note:(NSNotification *)n
{
	L(@"notification %@ %@", n.name, n.userInfo != nil ? n.userInfo : @"");
}

- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)c
{
	int n = ++_frames;
	CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);

	if (pb == NULL) {
		if (n <= 3) {
			L(@"frame %d: no image buffer", n);
		}
		return;
	}
	if (n <= 3 || n % 30 == 0) {
		OSType fmt = CVPixelBufferGetPixelFormatType(pb);
		size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), planes = CVPixelBufferGetPlaneCount(pb);
		unsigned long sum = 0, count = 0, max = 0;

		CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
		const unsigned char *base = planes > 0 ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb);
		size_t rows = planes > 0 ? CVPixelBufferGetHeightOfPlane(pb, 0) : h;
		size_t stride = planes > 0 ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb);
		size_t cols = planes > 0 ? CVPixelBufferGetWidthOfPlane(pb, 0) : w * 4;

		if (base != NULL) {
			for (size_t y = 0; y < rows; y += 8) {
				for (size_t x = 0; x < cols; x += 8) {
					unsigned v = base[y * stride + x];

					sum += v;
					count++;
					max = v > max ? v : max;
				}
			}
		}
		CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
		IOSurfaceRef sf = CVPixelBufferGetIOSurface(pb);

		L(@"frame %d: %c%c%c%c %zux%zu planes %zu, plane0 average %lu max %lu (%lu samples); IOSurface id %u (%zu bytes), buffer %p base %p", n,
		  (char)(fmt >> 24), (char)(fmt >> 16), (char)(fmt >> 8), (char)fmt, w, h, planes, count != 0 ? sum / count : 0, max, count,
		  sf != NULL ? IOSurfaceGetID(sf) : 0, sf != NULL ? IOSurfaceGetAllocSize(sf) : (size_t)0, pb, base);
	}
	if (n % 10 == 1) {
		/* a picture without CoreImage: the luma plane as grey, or the BGRA pixels, copied while the buffer is locked */
		size_t planes = CVPixelBufferGetPlaneCount(pb);
		OSType fmt = CVPixelBufferGetPixelFormatType(pb);
		CGColorSpaceRef cs = planes > 0 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB();
		CGImageRef cg = NULL;

		CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
		const void *base = planes > 0 ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb);
		size_t w = planes > 0 ? CVPixelBufferGetWidthOfPlane(pb, 0) : CVPixelBufferGetWidth(pb);
		size_t h = planes > 0 ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb);
		size_t stride = planes > 0 ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb);

		if (base != NULL && (planes > 0 || fmt == kCVPixelFormatType_32BGRA)) {
			CGContextRef c = CGBitmapContextCreate((void *)base, w, h, 8, stride, cs,
							       planes > 0 ? (CGBitmapInfo)kCGImageAlphaNone :
							       (kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little));

			if (c != NULL) {
				cg = CGBitmapContextCreateImage(c);
				CGContextRelease(c);
			}
		}
		CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
		CGColorSpaceRelease(cs);
		if (cg == NULL) {
			if (n <= 11) {
				L(@"frame %d: could not make an image", n);
			}
			return;
		}
		UIImage *img = [UIImage imageWithCGImage:cg];

		CGImageRelease(cg);
		dispatch_async(dispatch_get_main_queue(), ^{
			self.imageView.image = img;
		});
	}
}

- (void)addPreview
{
	CGRect b = [UIScreen mainScreen].bounds;

	L(@"making the preview layer");
	self.preview = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
	L(@"preview layer made: %@", self.preview);
	self.preview.frame = CGRectMake(0, 0, b.size.width, b.size.height / 2);
	self.preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
	[self.window.rootViewController.view.layer addSublayer:self.preview];
	L(@"preview layer added");
}

- (void)probe:(NSNumber *)when
{
	L(@"=== t=%@ s: frames %d, running %d, interrupted %d", when, _frames, self.session.isRunning, self.session.isInterrupted);
	if (self.preview == nil) {
		return;
	}
	L(@"preview layer %@ bounds %@ connection active %d enabled %d, sublayers %lu, contents %@", NSStringFromClass([self.preview class]),
	  NSStringFromCGRect(self.preview.bounds), self.preview.connection.isActive, self.preview.connection.isEnabled,
	  (unsigned long)self.preview.sublayers.count, self.preview.contents != nil ? @"yes" : @"no");
}

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts
{
	L(@"launched, camera authorization %ld", (long)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]);
	dump_authorization();
	if (getenv("CAMPROBE_NOFAKE") == NULL) {
		class_replaceMethod(object_getClass([AVCaptureDevice class]), @selector(authorizationStatusForMediaType:), (IMP)fake_status, "q@:@");
		class_replaceMethod(object_getClass([AVCaptureDevice class]), @selector(requestAccessForMediaType:completionHandler:), (IMP)fake_request, "v@:@@?");
		L(@"authorization faked: now %ld", (long)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]);
	}
	[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
		L(@"requestAccess: %d", granted);
	}];
	CGRect b = [UIScreen mainScreen].bounds;

	self.window = [[UIWindow alloc] initWithFrame:b];
	UIViewController *vc = [[UIViewController alloc] init];

	vc.view.backgroundColor = [UIColor blueColor];
	self.window.rootViewController = vc;
	self.session = [[AVCaptureSession alloc] init];
	NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];

	L(@"%lu video devices", (unsigned long)devices.count);
	AVCaptureDevice *d = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo
								      position:getenv("CAMPROBE_BACK") != NULL ? AVCaptureDevicePositionBack : AVCaptureDevicePositionFront];

	for (AVCaptureDevice *x in devices) {
		L(@"device %@ position %ld id %@", x.localizedName, (long)x.position, x.uniqueID);
	}
	if (d == nil) {
		d = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
	}
	NSError *err = nil;
	AVCaptureDeviceInput *in = d != nil ? [AVCaptureDeviceInput deviceInputWithDevice:d error:&err] : nil;

	L(@"device %@ input %@ error %@", d.localizedName, in, err);
	if (in != nil && [self.session canAddInput:in]) {
		[self.session addInput:in];
	}
	AVCaptureVideoDataOutput *out = [[AVCaptureVideoDataOutput alloc] init];

	out.alwaysDiscardsLateVideoFrames = YES;
	[out setSampleBufferDelegate:self queue:dispatch_queue_create("camprobe.frames", DISPATCH_QUEUE_SERIAL)];
	if ([self.session canAddOutput:out]) {
		[self.session addOutput:out];
	}
	L(@"output formats %lu", (unsigned long)out.availableVideoCVPixelFormatTypes.count);
	self.imageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, b.size.height / 2, b.size.width, b.size.height / 2)];
	self.imageView.contentMode = UIViewContentModeScaleAspectFill;
	self.imageView.clipsToBounds = YES;
	self.imageView.backgroundColor = [UIColor redColor];
	[vc.view addSubview:self.imageView];
	L(@"views made");
	[self.window makeKeyAndVisible];
	L(@"window visible");
	for (NSString *n in @[ AVCaptureSessionRuntimeErrorNotification, AVCaptureSessionWasInterruptedNotification,
			       AVCaptureSessionInterruptionEndedNotification, AVCaptureSessionDidStartRunningNotification,
			       AVCaptureSessionDidStopRunningNotification ]) {
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(note:) name:n object:self.session];
	}
	L(@"starting the session");
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		[self.session startRunning];
		L(@"startRunning returned, running %d", self.session.isRunning);
	});
	[self performSelector:@selector(addPreview) withObject:nil afterDelay:15.0];
	for (NSNumber *s in @[ @12, @30, @50 ]) {
		[self performSelector:@selector(probe:) withObject:s afterDelay:[s doubleValue]];
	}
	return YES;
}

@end

int
main(int argc, char **argv)
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, @"CPApp");
	}
}
