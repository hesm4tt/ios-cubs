/*
 * rwdefaults: set boolean/string preferences in iOS from a launchd job (there is no `defaults` tool in the image).
 *   rwdefaults bool DOMAIN KEY 0|1      DOMAIN "-g" = the global domain (kCFPreferencesAnyApplication)
 *   rwdefaults str  DOMAIN KEY VALUE
 * Why: WebKit's GPU process renders the page into IOSurfaces through Metal, and those surfaces stay all zero in iOS memory (the pixels
 * live on Android's GPU), so Safari's content area is black. Turning WebKit's GPU-process DOM rendering off makes WebContent draw with
 * CoreGraphics straight into the IOSurface. Build:
 *   xnu-clang -arch arm64 -isysroot $THEOS/sdks/iPhoneOS16.5.sdk -O1 -framework CoreFoundation -o rwdefaults rwdefaults.c
 */
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

int
main(int argc, char **argv)
{
	if (argc < 5) {
		fprintf(stderr, "usage: rwdefaults bool|str DOMAIN|-g KEY VALUE\n");
		return 2;
	}
	CFStringRef dom = strcmp(argv[2], "-g") == 0 ? kCFPreferencesAnyApplication :
	    CFStringCreateWithCString(NULL, argv[2], kCFStringEncodingUTF8);
	CFStringRef key = CFStringCreateWithCString(NULL, argv[3], kCFStringEncodingUTF8);
	CFTypeRef val;

	if (strcmp(argv[1], "bool") == 0) {
		val = atoi(argv[4]) ? kCFBooleanTrue : kCFBooleanFalse;
	} else {
		val = CFStringCreateWithCString(NULL, argv[4], kCFStringEncodingUTF8);
	}
	CFPreferencesSetValue(key, val, dom, CFSTR("mobile"), kCFPreferencesAnyHost);
	Boolean ok = CFPreferencesSynchronize(dom, CFSTR("mobile"), kCFPreferencesAnyHost);

	printf("rwdefaults: %s %s = %s: %s\n", argv[2], argv[3], argv[4], ok ? "ok" : "FAILED");
	return ok ? 0 : 1;
}
