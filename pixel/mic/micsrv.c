/*
 * micsrv: Android's end of the microphone of iOS. iOS's kernel (bsd/dev/redwood_cubs_mic.c, boot arg cubs_mic=1) makes /dev/redwood-mic; when iOS's audio server
 * opens it, the kernel sets ios_wants in a ring in the reserved RAM (/dev/cubs_ram, offset 0x1A20000) and this program opens the phone's microphone (AAudio,
 * 48 kHz mono 16-bit), puts the samples into the ring and stops the microphone again when iOS closes the device (the microphone is open only while iOS records).
 *   +0x0000 u32 magic "MIC1" (written here when this program is up)   +0x0040 u32 ios_wants (written by XNU)   +0x0080 u32 wr, frames written here
 *   +0x1000 the ring: RING_FRAMES int16 samples
 * Software gain MIC_GAIN (env, default 8): the unprocessed microphone is quiet.
 */
#include <aaudio/AAudio.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#define OFF 0x1A20000UL
#define RING_FRAMES 16384
#define MAGIC 0x3143494du       /* "MIC1" */

static int rfd;

static uint32_t
word(uint32_t o)
{
	uint32_t v = 0;

	(void)pread(rfd, &v, 4, OFF + o);
	return v;
}

static void
setword(uint32_t o, uint32_t v)
{
	(void)pwrite(rfd, &v, 4, OFF + o);
}

static void
ms(int n)
{
	struct timespec t = { n / 1000, (n % 1000) * 1000000L };

	nanosleep(&t, NULL);
}

static AAudioStream *
mic_open(void)
{
	AAudioStreamBuilder *b;
	AAudioStream *s;

	if (AAudio_createStreamBuilder(&b) != AAUDIO_OK) {
		return NULL;
	}
	AAudioStreamBuilder_setDirection(b, AAUDIO_DIRECTION_INPUT);
	AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_I16);
	AAudioStreamBuilder_setChannelCount(b, 1);
	AAudioStreamBuilder_setSampleRate(b, 48000);
	AAudioStreamBuilder_setPerformanceMode(b, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
	AAudioStreamBuilder_setInputPreset(b, AAUDIO_INPUT_PRESET_UNPROCESSED);
	if (AAudioStreamBuilder_openStream(b, &s) != AAUDIO_OK) {
		AAudioStreamBuilder_delete(b);
		return NULL;
	}
	AAudioStreamBuilder_delete(b);
	if (AAudioStream_requestStart(s) != AAUDIO_OK) {
		AAudioStream_close(s);
		return NULL;
	}
	return s;
}

static void
logt(const char *what, long n)
{
	time_t t = time(NULL);
	struct tm tm;
	char b[16];

	localtime_r(&t, &tm);
	strftime(b, sizeof b, "%H:%M:%S", &tm);
	printf("%s micsrv: %s %ld\n", b, what, n);
}

/*
 * One recording: the microphone is opened, its samples go to the ring until iOS closes the device (ios_wants = 0) or something goes wrong. It runs in a child
 * process, because AAudio can hang for good when Android's audio server dies (the framework restarts during iOS runs: its watchdog fires, class "main" is
 * restarted); the parent then kills it and starts a new one.
 */
static int
worker(int gain)
{
	static int16_t in[2400];
	uint32_t wr = word(0x80);
	AAudioStream *s = mic_open();
	unsigned long total = 0, last_log = 0;
	int peak = 0;

	if (s == NULL) {
		logt("the microphone cannot be opened (aaudio)", 0);
		return 1;
	}
	logt("microphone open", 0);
	while (word(0x40)) {
		aaudio_result_t n = AAudioStream_read(s, in, 480, 100 * 1000000LL);

		if (n < 0) {
			logt("read error", n);
			return 2;
		}
		if (n == 0) {
			continue;
		}
		for (int i = 0; i < n; i++) {
			int raw = in[i] < 0 ? -in[i] : in[i];

			peak = raw > peak ? raw : peak;
			int v = in[i] * gain;

			in[i] = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v);
		}
		for (aaudio_result_t done = 0; done < n;) {
			uint32_t at = wr % RING_FRAMES, k = (uint32_t)(n - done);

			if (k > RING_FRAMES - at) {
				k = RING_FRAMES - at;
			}
			(void)pwrite(rfd, in + done, k * 2, OFF + 0x1000 + (uint64_t)at * 2);
			wr += k;
			done += (aaudio_result_t)k;
		}
		setword(0x80, wr);
		total += (unsigned long)n;
		if (total - last_log >= 48000 * 2) {      /* every 2 s: how loud the raw microphone is (so a silent microphone can be told from a lost ring) */
			logt("raw peak of the last 2 s", peak);
			peak = 0;
			last_log = total;
		}
	}
	AAudioStream_requestStop(s);
	AAudioStream_close(s);
	logt("iOS stopped recording, frames", (long)total);
	return 0;
}

int
main(void)
{
	int gain = getenv("MIC_GAIN") ? atoi(getenv("MIC_GAIN")) : 8;
	pid_t child = 0;
	time_t began = 0, last_progress = 0;
	uint32_t last_wr = 0;
	unsigned long recordings = 0;

	setvbuf(stdout, NULL, _IOLBF, 0);
	rfd = open("/dev/cubs_ram", O_RDWR);
	if (rfd < 0) {
		perror("micsrv: /dev/cubs_ram");
		return 1;
	}
	setword(0x40, 0);
	setword(0x80, word(0x80));
	setword(0, MAGIC);
	logt("ready, gain", gain);
	for (;;) {
		int st;

		ms(50);
		if (child > 0 && waitpid(child, &st, WNOHANG) == child) {
			logt("worker ended, status", st);
			child = 0;
			if (word(0x40)) {
				ms(500);
			}
		}
		if (child == 0) {
			if (word(0x40)) {
				recordings++;
				logt("iOS records, start", (long)recordings);
				began = last_progress = time(NULL);
				last_wr = word(0x80);
				if ((child = fork()) == 0) {
					_exit(worker(gain));
				}
			}
			continue;
		}
		/* a worker is running: stalled (no new samples for 3 s, 5 s grace at the start)? or not needed any more? */
		uint32_t w = word(0x80);

		if (w != last_wr) {
			last_wr = w;
			last_progress = time(NULL);
		}
		time_t now = time(NULL);

		if (now - last_progress > (now - began < 60 ? 40 : 5) && word(0x40)) {
			logt("no samples, killing the worker", child);
			kill(child, SIGKILL);
		} else if (!word(0x40) && now - last_progress > 2) {
			kill(child, SIGKILL);
		}
	}
}
