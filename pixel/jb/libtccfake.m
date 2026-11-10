/*
 * libtccfake: there is no tccd here (launchd: "failed lookup com.apple.tccd"), so every privacy check ends "denied": the microphone and the camera
 * for every app (camera findings 2026-11-08), and the audio server refuses to open an input. This library answers the checks with "granted", in the
 * programs it is injected into (inject.conf: mediaserverd and the apps that record):
 *   - TCC.framework's C calls are interposed (TCCAccessPreflight -> 0 = granted, TCCAccessRequest -> the completion gets "granted",
 *     TCCAccessCheckAuditToken / TCCAccessPreflightWithAuditToken -> granted);
 *   - AVAudioSession's recordPermission / requestRecordPermission: and AVCaptureDevice's authorizationStatusForMediaType: /
 *     requestAccessForMediaType:completionHandler: are replaced once their frameworks are loaded.
 * Logs to /tmp/tccfake.log.
 *   xnu-clang -arch arm64 -isysroot $THEOS/sdks/iPhoneOS16.5.sdk -fno-objc-arc -O1 -dynamiclib -F$THEOS/sdks/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks \
 *       -framework Foundation -framework TCC -lobjc -o libtccfake.dylib libtccfake.m
 */
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <mach/message.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern int TCCAccessPreflight(CFStringRef service, CFDictionaryRef options);
extern void TCCAccessRequest(CFStringRef service, CFDictionaryRef options, void (^completion)(Boolean granted));
extern Boolean TCCAccessCheckAuditToken(CFStringRef service, audit_token_t token, CFDictionaryRef options);
extern int TCCAccessPreflightWithAuditToken(CFStringRef service, audit_token_t token, CFDictionaryRef options);

static int gLogged;

static void
tlog(const char *what, CFStringRef service)
{
	if (gLogged++ > 40) {
		return;
	}
	FILE *f = fopen("/tmp/tccfake.log", "a");

	if (f != NULL) {
		char buf[96] = "";

		if (service != NULL) {
			CFStringGetCString(service, buf, sizeof buf, kCFStringEncodingUTF8);
		}
		fprintf(f, "tccfake[%d]: %s %s\n", getpid(), what, buf);
		fclose(f);
	}
}

static int
my_preflight(CFStringRef service, CFDictionaryRef options)
{
	tlog("TCCAccessPreflight -> granted", service);
	return 0;       /* kTCCAccessPreflightGranted */
}

static void
my_request(CFStringRef service, CFDictionaryRef options, void (^completion)(Boolean granted))
{
	tlog("TCCAccessRequest -> granted", service);
	if (completion != NULL) {
		completion(true);
	}
}

static Boolean
my_check(CFStringRef service, audit_token_t token, CFDictionaryRef options)
{
	tlog("TCCAccessCheckAuditToken -> granted", service);
	return true;
}

static int
my_preflight_token(CFStringRef service, audit_token_t token, CFDictionaryRef options)
{
	tlog("TCCAccessPreflightWithAuditToken -> granted", service);
	return 0;
}

#define INTERPOSE(replacement, replacee) \
	__attribute__((used)) static struct { const void *r; const void *o; } _interpose_##replacee \
	__attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&replacee }

INTERPOSE(my_preflight, TCCAccessPreflight);
INTERPOSE(my_request, TCCAccessRequest);
INTERPOSE(my_check, TCCAccessCheckAuditToken);
INTERPOSE(my_preflight_token, TCCAccessPreflightWithAuditToken);

/* ---- AVFoundation ---- */
static NSUInteger
fake_record_permission(id self, SEL _cmd)
{
	return 0x67726e74;      /* AVAudioSessionRecordPermissionGranted 'grnt' */
}

static void
fake_request_record(id self, SEL _cmd, void (^response)(BOOL granted))
{
	if (response != nil) {
		response(YES);
	}
}

static NSInteger
fake_auth_status(id self, SEL _cmd, NSString *type)
{
	return 3;       /* AVAuthorizationStatusAuthorized */
}

static void
fake_request_access(id self, SEL _cmd, NSString *type, void (^handler)(BOOL))
{
	if (handler != nil) {
		handler(YES);
	}
}

static void
replace(Class c, SEL s, IMP imp, BOOL meta)
{
	Method m = meta ? class_getClassMethod(c, s) : class_getInstanceMethod(c, s);

	if (m != NULL) {
		method_setImplementation(m, imp);
	}
}

static void
swizzle_av(void)
{
	static int done_audio, done_capture;
	Class s = objc_getClass("AVAudioSession"), d = objc_getClass("AVCaptureDevice");

	if (s != Nil && !done_audio) {
		replace(s, sel_registerName("recordPermission"), (IMP)fake_record_permission, NO);
		replace(s, sel_registerName("requestRecordPermission:"), (IMP)fake_request_record, NO);
		done_audio = 1;
		tlog("AVAudioSession permission replaced", NULL);
	}
	if (d != Nil && !done_capture) {
		replace(d, sel_registerName("authorizationStatusForMediaType:"), (IMP)fake_auth_status, YES);
		replace(d, sel_registerName("requestAccessForMediaType:completionHandler:"), (IMP)fake_request_access, YES);
		done_capture = 1;
		tlog("AVCaptureDevice authorization replaced", NULL);
	}
}

static void
image_added(const struct mach_header *mh, intptr_t slide)
{
	swizzle_av();
}

__attribute__((constructor)) static void
tccfake_init(void)
{
	tlog("loaded", NULL);
	swizzle_av();
	_dyld_register_func_for_add_image(image_added);
}
