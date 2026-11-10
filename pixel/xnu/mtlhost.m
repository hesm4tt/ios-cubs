/*
 * libmtlhost.dylib: injected into SpringBoard (INJECT line "/redwood/bin/libmtlhost.dylib SpringBoard"). Waits for
 * /var/tmp/metalproc.ctx (the CAContext id of the separate process metalproc, which draws with Metal on the PowerVR) and puts a
 * CALayerHost for that context on SpringBoard's window: the other process's layer tree, composited by iOS's render server.
 */
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>

static void
say(const char *format, ...)
{
	char line[300];
	va_list ap;
	int con = open("/dev/console", O_WRONLY);

	va_start(ap, format);
	int n = vsnprintf(line, sizeof line, format, ap);
	va_end(ap);
	if (con >= 0) {
		if (n > 0) {
			(void)write(con, line, (size_t)(n < (int)sizeof line ? n : (int)sizeof line - 1));
		}
		close(con);
	}
}

static CALayer *host;

static void
attach(unsigned cid)
{
	UIApplication *app = [UIApplication sharedApplication];
	UIWindow *best = nil;

	for (UIWindow *w in [app windows]) {
		if (!w.hidden && w.bounds.size.width > 300 && (!best || w.windowLevel >= best.windowLevel)) {
			best = w;
		}
	}
	Class hostClass = NSClassFromString(@"CALayerHost");

	if (!best || !hostClass) {
		say("mtlhost: no window (%p) or no CALayerHost (%p)\n", best, hostClass);
		return;
	}
	host = [[hostClass alloc] init];
	[host setValue:@(cid) forKey:@"contextId"];
	host.frame = CGRectMake(40, 520, 256, 256);
	host.cornerRadius = 24;
	host.masksToBounds = YES;
	host.borderWidth = 3;
	host.borderColor = [UIColor greenColor].CGColor;
	host.zPosition = 1000000;
	[best.layer addSublayer:host];
	say("mtlhost: CALayerHost for context %u added to a %s\n", cid, object_getClassName(best));
}

static void *
watch(void *arg)
{
	(void)arg;
	sleep(60);
	for (int i = 0; i < 600 && !host; i++) {
		FILE *f = fopen("/var/tmp/metalproc.ctx", "r");
		unsigned cid = 0;

		if (f) {
			if (fscanf(f, "%u", &cid) != 1) {
				cid = 0;
			}
			fclose(f);
		}
		if (cid) {
			dispatch_async(dispatch_get_main_queue(), ^{
				if (!host) {
					attach(cid);
				}
			});
		}
		sleep(3);
	}
	return NULL;
}

__attribute__((constructor)) static void
start(void)
{
	pthread_t t;

	if (pthread_create(&t, NULL, watch, NULL) == 0) {
		pthread_detach(t);
	}
}
