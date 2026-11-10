/*
 * sbslaunch: ask SpringBoard to launch an app by bundle id (SBSLaunchApplicationWithIdentifier). Needs the entitlements of lsprobe.entitlements
 * (com.apple.springboard.launchapplications, com.apple.frontboard.launchapplications). Prints "sbslaunch: <id> rc=<n> (<text>)", rc 0 = launched.
 *   xnu-clang -arch arm64 -isysroot $THEOS/sdks/iPhoneOS16.5.sdk -O1 -framework CoreFoundation -o sbslaunch sbslaunch.c && ldid -Slsprobe.entitlements sbslaunch
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>

int
main(int argc, char **argv)
{
	void *sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
	int (*launch)(CFStringRef, Boolean) = sbs ? dlsym(sbs, "SBSLaunchApplicationWithIdentifier") : NULL;
	CFStringRef (*errstr)(int) = sbs ? dlsym(sbs, "SBSApplicationLaunchingErrorString") : NULL;

	if (launch == NULL || argc < 2) {
		printf("sbslaunch: no SpringBoardServices or no bundle id\n");
		return 1;
	}
	for (int i = 1; i < argc; i++) {
		CFStringRef id = CFStringCreateWithCString(NULL, argv[i], kCFStringEncodingUTF8);
		int rc = launch(id, 0);
		char text[128] = "?";

		if (errstr != NULL) {
			CFStringGetCString(errstr(rc), text, sizeof text, kCFStringEncodingUTF8);
		}
		printf("sbslaunch: %s rc=%d (%s)\n", argv[i], rc, text);
		fflush(stdout);
	}
	return 0;
}
