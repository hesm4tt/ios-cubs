/*
 * dltest: do CADisplayLink callbacks (WebKit's rendering updates and the camera preview ride on them) fire in this iOS, and how often?
 * Run as a launchd job after SpringBoard is up. Prints "dltest: ..." lines: ticks per second for 10 s from the main run loop.
 *   xnu-clang -arch arm64 -isysroot $THEOS/sdks/iPhoneOS16.5.sdk -fno-objc-arc -O1 -framework Foundation -framework QuartzCore -framework UIKit -o dltest dltest.m
 */
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>

@interface Ticker : NSObject {
@public
	int n;
	double first, last;
}
- (void)tick:(CADisplayLink *)l;
@end

@implementation Ticker
- (void)tick:(CADisplayLink *)l
{
	if (n == 0) {
		first = CACurrentMediaTime();
	}
	last = CACurrentMediaTime();
	n++;
}
@end

int
main(void)
{
	@autoreleasepool {
		printf("dltest: start\n");
		fflush(stdout);
		Ticker *t = [[Ticker alloc] init];
		UIScreen *screen = [UIScreen mainScreen];

		printf("dltest: screen %p bounds %.0fx%.0f scale %.1f\n", screen, screen.bounds.size.width, screen.bounds.size.height, screen.scale);
		fflush(stdout);
		CADisplayLink *l = [screen displayLinkWithTarget:t selector:@selector(tick:)];

		printf("dltest: display link %p\n", l);
		fflush(stdout);
		[l addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
		for (int s = 1; s <= 10; s++) {
			[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
			printf("dltest: after %d s: %d ticks%s\n", s, t->n, t->n > 1 ? "" : " (none)");
			fflush(stdout);
		}
		if (t->n > 1) {
			printf("dltest: %.1f ticks a second over %.1f s\n", (t->n - 1) / (t->last - t->first), t->last - t->first);
		} else {
			printf("dltest: the display link never fired\n");
		}
		[l invalidate];
	}
	return 0;
}
