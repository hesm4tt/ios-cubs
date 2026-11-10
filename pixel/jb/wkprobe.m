/*
 * wkprobe: why does a WKWebView (Safari's page area) show black here? A small app (com.cubs.wkprobe, baked into /Applications) with three
 * WKWebViews stacked on the screen, each with its own WebContent process and a page of its own colour:
 *   A (top, red)     default preferences
 *   B (middle, green) accelerated drawing / canvas acceleration / display lists switched off
 *   C (bottom, yellow) the GPU process switched off for DOM, canvas, media and WebGL
 * At 15, 30 and 50 s each prints (NSLog, which reaches the kernel log as "wkprobe: ..."): what the page says about itself (visibilityState,
 * size, body colour), the average colour of a snapshot taken by WebKit itself (WebContent painting with CoreGraphics, no remote layers),
 * and the layer tree of the web view. The screenshot ring shows which band really reaches the panel. Also counts CADisplayLink ticks.
 *   xnu-clang -arch arm64 -isysroot $THEOS/sdks/iPhoneOS16.5.sdk -fno-objc-arc -O1 -framework Foundation -framework UIKit -framework WebKit \
 *       -framework QuartzCore -framework CoreGraphics -o WKProbe wkprobe.m
 */
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <QuartzCore/QuartzCore.h>

static int gTicks;

/* NSLog goes nowhere for an app here, so every line is also appended to /tmp/wkprobe.log (a boot job prints it) */
static void
L(NSString *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];

	va_end(ap);
	NSLog(@"wkprobe: %@", s);
	FILE *f = fopen("/tmp/wkprobe.log", "a");

	if (f != NULL) {
		fprintf(f, "wkprobe: %s\n", [s UTF8String]);
		fclose(f);
	}
}

@interface WPTick : NSObject
- (void)tick:(CADisplayLink *)l;
@end

@implementation WPTick
- (void)tick:(CADisplayLink *)l
{
	gTicks++;
}
@end

static void
average(UIImage *img, NSString *what)
{
	if (img == nil || img.CGImage == NULL) {
		L(@"%@: snapshot: no image", what);
		return;
	}
	unsigned char px[4] = { 0, 0, 0, 0 };
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGContextRef c = CGBitmapContextCreate(px, 1, 1, 8, 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);

	CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
	CGContextDrawImage(c, CGRectMake(0, 0, 1, 1), img.CGImage);
	L(@"%@: snapshot %.0fx%.0f, average RGBA %d %d %d %d", what, img.size.width, img.size.height, px[0], px[1], px[2], px[3]);
	CGContextRelease(c);
	CGColorSpaceRelease(cs);
}

static NSString *
tree(CALayer *l, int depth)
{
	NSMutableString *s = [NSMutableString string];

	[s appendFormat:@"%*s%@ %.0fx%.0f contents=%@ hidden=%d\n", depth * 2, "", NSStringFromClass([l class]), l.bounds.size.width,
	 l.bounds.size.height, l.contents != nil ? @"yes" : @"no", l.hidden];
	if (depth < 4) {
		for (CALayer *k in l.sublayers) {
			[s appendString:tree(k, depth + 1)];
		}
	}
	return s;
}

@interface WPApp : UIResponder <UIApplicationDelegate>
@property (nonatomic, retain) UIWindow *window;
@property (nonatomic, retain) NSArray *views;
@property (nonatomic, retain) NSArray *names;
@end

@implementation WPApp

- (WKWebView *)makeView:(CGRect)frame name:(NSString *)name off:(NSArray *)off color:(NSString *)color
{
	WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];

	cfg.processPool = [[WKProcessPool alloc] init];
	for (NSString *k in off) {
		@try {
			[cfg.preferences setValue:@NO forKey:k];
			L(@"%@: %@ = NO", name, k);
		} @catch (NSException *e) {
			L(@"%@: %@ not settable: %@", name, k, e.reason);
		}
	}
	WKWebView *v = [[WKWebView alloc] initWithFrame:frame configuration:cfg];
	NSString *html = [NSString stringWithFormat:@"<html><head><meta name=viewport content='width=device-width'></head>"
			  "<body style='margin:0;background:%@;color:#000;font:bold 64px sans-serif'>WKPROBE %@</body></html>", color, name];

	[v loadHTMLString:html baseURL:nil];
	return v;
}

- (void)probe:(NSNumber *)when
{
	L(@"=== t=%@ s: app state %ld, window key %d, display link ticks %d", when, (long)[UIApplication sharedApplication].applicationState,
	      self.window.isKeyWindow, gTicks);
	for (NSUInteger i = 0; i < self.views.count; i++) {
		WKWebView *v = self.views[i];
		NSString *n = self.names[i];

		[v evaluateJavaScript:@"document.visibilityState+' '+innerWidth+'x'+innerHeight+' body='+getComputedStyle(document.body).backgroundColor+' text='+document.body.innerText"
		    completionHandler:^(id r, NSError *err) {
			L(@"%@: js %@ %@", n, r, err != nil ? err : @"");
		}];
		WKSnapshotConfiguration *sc = [[WKSnapshotConfiguration alloc] init];

		[v takeSnapshotWithConfiguration:sc completionHandler:^(UIImage *img, NSError *err) {
			average(img, n);
			if (err != nil) {
				L(@"%@: snapshot error %@", n, err);
			}
		}];
		if ([when intValue] == 30) {
			L(@"%@: layers:\n%@", n, tree(v.layer, 0));
		}
	}
}

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts
{
	L(@"launched");
	CGRect b = [UIScreen mainScreen].bounds;
	CGFloat h = b.size.height / 4;

	self.window = [[UIWindow alloc] initWithFrame:b];
	UIViewController *vc = [[UIViewController alloc] init];

	vc.view.backgroundColor = [UIColor blueColor];
	self.window.rootViewController = vc;
	WKWebView *a = [self makeView:CGRectMake(0, 0, b.size.width, h) name:@"A-default" off:@[] color:@"#ff0000"];
	WKWebView *b1 = [self makeView:CGRectMake(0, h, b.size.width, h) name:@"B1-noAccelDrawing" off:@[ @"acceleratedDrawingEnabled" ] color:@"#00ff00"];
	WKWebView *b2 = [self makeView:CGRectMake(0, 2 * h, b.size.width, h) name:@"B2-noDisplayList" off:@[ @"displayListDrawingEnabled" ] color:@"#ffff00"];
	WKWebView *b3 = [self makeView:CGRectMake(0, 3 * h, b.size.width, h) name:@"B3-noCanvasAccel" off:@[ @"canvasUsesAcceleratedDrawing" ] color:@"#00ffff"];

	self.views = @[ a, b1, b2, b3 ];
	self.names = @[ @"A-default", @"B1-noAccelDrawing", @"B2-noDisplayList", @"B3-noCanvasAccel" ];
	for (UIView *v in self.views) {
		[vc.view addSubview:v];
	}
	[self.window makeKeyAndVisible];
	WPTick *t = [[WPTick alloc] init];
	CADisplayLink *l = [[UIScreen mainScreen] displayLinkWithTarget:t selector:@selector(tick:)];

	[l addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
	for (NSNumber *s in @[ @15, @30, @50 ]) {
		[self performSelector:@selector(probe:) withObject:s afterDelay:[s doubleValue]];
	}
	return YES;
}

@end

int
main(int argc, char **argv)
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, @"WPApp");
	}
}
