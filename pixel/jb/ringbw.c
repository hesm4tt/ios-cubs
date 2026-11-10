/*
 * ringbw: memory bandwidth inside iOS: memcpy RAM->RAM, pread from the GPU ring (/dev/cubs-gpu) and pwrite to it, in MB/s, so that the
 * per-frame copies of the GL forwarder (10.8 MB in, 13.9 MB out) can be compared with what the hardware does. Run as a launchd job:
 *   xnu-clang -arch arm64 -isysroot $THEOS/sdks/iPhoneOS16.5.sdk -O2 -o ringbw ringbw.c
 */
#include <fcntl.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static double
secs(uint64_t a, uint64_t b)
{
	static mach_timebase_info_data_t tb;

	if (tb.denom == 0) {
		mach_timebase_info(&tb);
	}
	return (double)(b - a) * tb.numer / tb.denom / 1e9;
}

int
main(void)
{
	size_t n = 12u << 20;
	char *a = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
	char *b = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
	int fd = open("/dev/cubs-gpu", O_RDWR);

	if (a == MAP_FAILED || b == MAP_FAILED) {
		printf("ringbw: no memory\n");
		return 1;
	}
	memset(a, 1, n);
	memset(b, 2, n);
	for (int round = 0; round < 3; round++) {
		uint64_t t0 = mach_absolute_time();

		memcpy(a, b, n);
		uint64_t t1 = mach_absolute_time();
		printf("ringbw: round %d: memcpy RAM->RAM %.0f MB/s", round, n / 1048576.0 / secs(t0, t1));
		if (fd >= 0) {
			t0 = mach_absolute_time();
			ssize_t r = pread(fd, a, n, 0x10000);
			t1 = mach_absolute_time();
			printf("; pread ring->RAM %.0f MB/s (%zd bytes)", r / 1048576.0 / secs(t0, t1), r);
			t0 = mach_absolute_time();
			ssize_t w = pwrite(fd, b, n, 0x10000);
			t1 = mach_absolute_time();
			printf("; pwrite RAM->ring %.0f MB/s (%zd bytes)", w / 1048576.0 / secs(t0, t1), w);
			t0 = mach_absolute_time();
			for (size_t o = 0; o < n; o += 65536) {
				(void)pread(fd, a + o, 65536, 0x10000 + o);
			}
			t1 = mach_absolute_time();
			printf("; pread 64K chunks %.0f MB/s", n / 1048576.0 / secs(t0, t1));
		} else {
			printf("; no /dev/cubs-gpu");
		}
		printf("\n");
		fflush(stdout);
	}
	return 0;
}
