/*
 * brightbridge: carries iOS's screen brightness to the panel's backlight, which is Android's. backboardd keeps the level
 * (the Control Center slider and Settings set it through BackBoardServices); nothing here owns a backlight, so the level reached no hardware
 * and the panel stayed at whatever Android had left (very dark in a dim room).
 *   brightbridge          loop: every second read the level (BKSDisplayBrightnessGetCurrent); when it changed, tell persistsrv on Android
 *                         (GET http://10.77.0.1:8099/brightness/<thousandths>), which writes /sys/class/backlight/panel0-backlight
 *   brightbridge sweep    first set the level 0.15, 0.5, 1.0, 0.5 (8 s apart, as the slider would) to show that the chain follows it
 * Lines start with "brightbridge:". Built (iOS SDK) and signed with brightbridge.entitlements:
 *   xnu-clang -arch arm64 -isysroot $THEOS/sdks/iPhoneOS16.5.sdk -O1 -o brightbridge brightbridge.c && ldid -Sbrightbridge.entitlements brightbridge
 */
#include <dlfcn.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static int
send_level(float level)
{
	char url[128];
	int pm = (int)(level * 1000.0f + 0.5f);
	char *argv[] = { "/redwood/bin/rwhttp", "get", url, "/dev/null", NULL };
	pid_t pid;
	int st = 0;

	snprintf(url, sizeof url, "http://10.77.0.1:8099/brightness/%d", pm);
	if (posix_spawn(&pid, argv[0], NULL, NULL, argv, environ) == 0) {
		waitpid(pid, &st, 0);
	}
	printf("brightbridge: level %.3f (%d/1000) sent, rwhttp status %d\n", level, pm, st);
	fflush(stdout);
	return st == 0;
}

int
main(int argc, char **argv)
{
	void *bbs = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
	float (*get)(void) = bbs ? dlsym(bbs, "BKSDisplayBrightnessGetCurrent") : NULL;
	void (*set)(float, int) = bbs ? dlsym(bbs, "BKSDisplayBrightnessSet") : NULL;
	float last = -1.0f;

	printf("brightbridge: start BackBoardServices %p get %p set %p\n", bbs, (void *)get, (void *)set);
	fflush(stdout);
	if (get == NULL) {
		return 1;
	}
	if (argc > 1 && strcmp(argv[1], "sweep") == 0 && set != NULL) {
		static const float steps[] = { 0.15f, 0.5f, 1.0f, 0.5f };

		for (int i = 0; i < 4; i++) {
			set(steps[i], 1);
			printf("brightbridge: set %.2f, now reads %.3f\n", steps[i], get());
			fflush(stdout);
			for (int s = 0; s < 8; s++) {
				float l = get();

				if (l - last > 0.004f || last - l > 0.004f) {
					if (send_level(l)) {
						last = l;
					}
				}
				sleep(1);
			}
		}
	}
	for (;;) {
		float l = get();

		if (l - last > 0.004f || last - l > 0.004f) {
			if (send_level(l)) {
				last = l;
			}
		}
		sleep(1);
	}
}
