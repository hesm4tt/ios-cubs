/*
 * libmgset.dylib: injected into lsd (and SpringBoard). During iOS first boot on this port two MobileGestalt questions that need
 * MobileGestaltHelper -- UniqueDeviceID and WifiAddress -- never get an answer, lsd blocks on them for 16 minutes and SpringBoard
 * waits for lsd. Here the answers are set up front with MGSetAnswer, so nobody asks the helper (found with liblsdprobe).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef bool (*mgset_fn)(CFStringRef question, CFTypeRef answer);

__attribute__((constructor)) static void
start(void)
{
	mgset_fn set = (mgset_fn)dlsym(RTLD_DEFAULT, "MGSetAnswer");
	int con = open("/dev/console", O_WRONLY);
	char b[160];
	int n;

	if (!set) {
		void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);

		set = h ? (mgset_fn)dlsym(h, "MGSetAnswer") : NULL;
	}
	if (!set) {
		n = snprintf(b, sizeof b, "mgset: MGSetAnswer not found\n");
		if (con >= 0) {
			(void)write(con, b, (size_t)n);
		}
		return;
	}
	bool a = set(CFSTR("UniqueDeviceID"), CFSTR("00008120-000A1B2C3D4E5F60"));
	bool w = set(CFSTR("WifiAddress"), CFSTR("02:00:00:00:00:01"));

	n = snprintf(b, sizeof b, "mgset: UniqueDeviceID %d WifiAddress %d\n", a, w);
	if (con >= 0) {
		(void)write(con, b, (size_t)n);
		close(con);
	}
}
