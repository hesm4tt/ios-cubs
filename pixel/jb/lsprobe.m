/*
 * lsprobe: why does SpringBoard refuse to open a sideloaded app's URL scheme? Prints what LaunchServices knows about two apps and the schemes.
 * Run as a launchd job after SpringBoard is up. Lines start with "lsprobe:".
 *   xnu-clang -arch arm64 -isysroot $THEOS/sdks/iPhoneOS16.5.sdk -fno-objc-arc -O1 -framework Foundation -framework CoreFoundation -o lsprobe lsprobe.m
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#define P(...) do { printf("lsprobe: " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

static id msg0(id o, const char *sel)
{
	SEL s = sel_registerName(sel);
	if (!o || ![o respondsToSelector:s]) {
		return nil;
	}
	return ((id (*)(id, SEL))objc_msgSend)(o, s);
}

static BOOL bmsg0(id o, const char *sel)
{
	SEL s = sel_registerName(sel);
	if (!o || ![o respondsToSelector:s]) {
		return NO;
	}
	return ((BOOL (*)(id, SEL))objc_msgSend)(o, s);
}

static void dump(id ws, NSString *bid)
{
	Class lap = NSClassFromString(@"LSApplicationProxy");
	id p = ((id (*)(id, SEL, id))objc_msgSend)(lap, sel_registerName("applicationProxyForIdentifier:"), bid);
	P("== %s proxy %p", [bid UTF8String], p);
	if (!p) {
		return;
	}
	P("  bundleURL %s", [[msg0(p, "bundleURL") description] UTF8String]);
	P("  bundleContainerURL %s", [[msg0(p, "bundleContainerURL") description] UTF8String]);
	P("  dataContainerURL %s", [[msg0(p, "dataContainerURL") description] UTF8String]);
	P("  isInstalled %d isRestricted %d isPlaceholder %d isContainerized %d", bmsg0(p, "isInstalled"), bmsg0(p, "isRestricted"),
	  bmsg0(p, "isPlaceholder"), bmsg0(p, "isContainerized"));
	P("  appType %s  signer %s  isAppStoreVendable %d", [[msg0(p, "applicationType") description] UTF8String],
	  [[msg0(p, "signerIdentity") description] UTF8String], bmsg0(p, "isAppStoreVendable"));
	P("  appState: %s", [[msg0(p, "appState") description] UTF8String]);
	P("  claimedURLSchemes %s", [[msg0(p, "claimedURLSchemes") description] UTF8String]);
	P("  entitlements: %s", [[msg0(p, "entitlements") description] UTF8String]);
	P("  canOpen? isLaunchProhibited %d", bmsg0(p, "isLaunchProhibited"));
}

int
main(void)
{
	@autoreleasepool {
		P("start");
		/* the classes live in private frameworks that nothing here links */
		P("dlopen MobileCoreServices %p CoreServices %p", dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW),
		  dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW));
		Class wsc = NSClassFromString(@"LSApplicationWorkspace");
		id ws = msg0((id)wsc, "defaultWorkspace");
		P("workspace %p", ws);
		NSArray *ids = @[ @"com.cubs.persisttest", @"com.apple.MetalDemo", @"com.apple.mobilesafari" ];
		SEL appInst = sel_registerName("applicationIsInstalled:");
		for (NSString *b in ids) {
			BOOL inst = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, appInst, b);
			P("applicationIsInstalled %s: %d", [b UTF8String], inst);
			dump(ws, b);
		}
		for (NSString *u in @[ @"persisttest://x", @"metaldemo://x", @"https://example.com/" ]) {
			NSURL *url = [NSURL URLWithString:u];
			id h = ((id (*)(id, SEL, id))objc_msgSend)(ws, sel_registerName("applicationsAvailableForHandlingURLScheme:"), [url scheme]);
			P("handlers for %s: %s", [[url scheme] UTF8String], [[h description] UTF8String]);
			id o = ((id (*)(id, SEL, id))objc_msgSend)(ws, sel_registerName("URLOverrideForURL:"), url);
			P("override for %s: %s", [u UTF8String], [[o description] UTF8String]);
			BOOL can = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, sel_registerName("openURL:"), url);
			P("openURL %s: %d", [u UTF8String], can);
		}
		/* SpringBoardServices: is the screen locked, and what error does each launch give (with its text) */
		void *sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
		int (*launch)(CFStringRef, Boolean) = sbs ? dlsym(sbs, "SBSLaunchApplicationWithIdentifier") : NULL;
		CFStringRef (*errstr)(int) = sbs ? dlsym(sbs, "SBSApplicationLaunchingErrorString") : NULL;
		void (*lockst)(Boolean *, Boolean *) = sbs ? dlsym(sbs, "SBGetScreenLockStatus") : NULL;
		P("SpringBoardServices %p launch %p errstr %p lockstatus %p", sbs, launch, errstr, lockst);
		if (lockst) {
			Boolean l = 0, pw = 0;
			lockst(&l, &pw);
			P("screen locked %d passcode %d", l, pw);
		}
		if (launch) {
			for (NSString *b in @[ @"com.apple.Preferences", @"com.redwood.metaldemo", @"com.cubs.persisttest" ]) {
				int rc = launch((CFStringRef)b, 0);
				P("SBSLaunchApplicationWithIdentifier %s: %d (%s)", [b UTF8String], rc,
				  errstr ? [(NSString *)errstr(rc) UTF8String] : "?");
				[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:6.0]];
			}
		}
		if (launch) {
			/* SpringBoard may still be starting (after a respring): ask every 5 s for up to 110 s until it launches the sideloaded app */
			for (int i = 0; i < 70; i++) {
				int rc = launch((CFStringRef) @"com.cubs.persisttest", 0);
				P("poll %d: SBSLaunchApplicationWithIdentifier com.cubs.persisttest: %d (%s)", i, rc, errstr ? [(NSString *)errstr(rc) UTF8String] : "?");
				if (rc == 0) {
					break;
				}
				[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:5.0]];
			}
		}
		P("openApplicationWithBundleID persisttest: %d",
		  ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, sel_registerName("openApplicationWithBundleID:"), @"com.cubs.persisttest"));
		[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3.0]];
		P("done");
	}
	return 0;
}
