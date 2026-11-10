/*
 * libwkfix: makes web views draw here. Found with wkprobe (2026-11-08): of four WKWebViews only the one whose preference "accelerated drawing" was
 * switched off showed its page; with the default (on) the tiles' IOSurfaces stay empty and the page area is black (Safari, SFSafariViewController,
 * every app with a WKWebView). WebKit ignores the user defaults for this preference (release builds read them only for internal features), so
 * the preference is set where the objects are made: -[WKPreferences init] and -[WKWebViewConfiguration init] call -_setAcceleratedDrawingEnabled:NO.
 * Injected like the other libredwood-* libraries (INJECT line: /redwood/bin/libwkfix.dylib MobileSafari WKProbe ...). Logs to /tmp/wkfix.log.
 *   xnu-clang -arch arm64 -isysroot $THEOS/sdks/iPhoneOS16.5.sdk -fno-objc-arc -O1 -dynamiclib -framework Foundation -lobjc -o libwkfix.dylib libwkfix.m
 */
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void wkfix_log(const char *s)
{
	FILE *f = fopen("/tmp/wkfix.log", "a");

	if (f != NULL) {
		fprintf(f, "wkfix[%d]: %s\n", getpid(), s);
		fclose(f);
	}
}

static IMP gPrefsInit, gConfigInit, gWebViewInit, gSetter;
static int gCalls;

static void
switch_off(id prefs)
{
	SEL s = sel_registerName("_setAcceleratedDrawingEnabled:");

	if (prefs != nil && [prefs respondsToSelector:s]) {
		((void (*)(id, SEL, BOOL))objc_msgSend)(prefs, s, NO);
		if (gCalls++ < 8) {
			wkfix_log("accelerated drawing switched off");
		}
	}
}

static id
prefs_init(id self, SEL _cmd)
{
	id r = ((id (*)(id, SEL))gPrefsInit)(self, _cmd);

	switch_off(r);
	return r;
}

static id
config_init(id self, SEL _cmd)
{
	id r = ((id (*)(id, SEL))gConfigInit)(self, _cmd);

	if (r != nil) {
		switch_off(((id (*)(id, SEL))objc_msgSend)(r, sel_registerName("preferences")));
	}
	return r;
}

/* a caller that switches it on again (Safari sets its own preferences) is overruled */
static void
setter(id self, SEL _cmd, BOOL on)
{
	if (on && gCalls++ < 16) {
		wkfix_log("someone set accelerated drawing ON: overruled");
	}
	((void (*)(id, SEL, BOOL))gSetter)(self, _cmd, NO);
}

static id
webview_init(id self, SEL _cmd, CGRect frame, id configuration)
{
	if (configuration != nil) {
		switch_off(((id (*)(id, SEL))objc_msgSend)(configuration, sel_registerName("preferences")));
	}
	return ((id (*)(id, SEL, CGRect, id))gWebViewInit)(self, _cmd, frame, configuration);
}

static void
try_hook(void)
{
	static int done;
	Class p = objc_getClass("WKPreferences"), c = objc_getClass("WKWebViewConfiguration");

	if (done || p == Nil || c == Nil) {
		return;
	}
	done = 1;
	Method m = class_getInstanceMethod(p, sel_registerName("init"));

	if (m != NULL) {
		gPrefsInit = method_setImplementation(m, (IMP)prefs_init);
	}
	m = class_getInstanceMethod(c, sel_registerName("init"));
	if (m != NULL) {
		gConfigInit = method_setImplementation(m, (IMP)config_init);
	}
	m = class_getInstanceMethod(p, sel_registerName("_setAcceleratedDrawingEnabled:"));
	if (m != NULL) {
		gSetter = method_setImplementation(m, (IMP)setter);
	}
	m = class_getInstanceMethod(objc_getClass("WKWebView"), sel_registerName("initWithFrame:configuration:"));
	if (m != NULL) {
		gWebViewInit = method_setImplementation(m, (IMP)webview_init);
	}
	wkfix_log("hooks installed");
}

static void
image_added(const struct mach_header *mh, intptr_t slide)
{
	Dl_info info;

	if (dladdr(mh, &info) != 0 && info.dli_fname != NULL && strstr(info.dli_fname, "/WebKit.framework/WebKit") != NULL) {
		try_hook();
	}
}

__attribute__((constructor)) static void
wkfix_init(void)
{
	wkfix_log("loaded");
	try_hook();
	_dyld_register_func_for_add_image(image_added);
}
