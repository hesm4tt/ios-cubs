/*
 * micprobe: can a root native process on the Pixel capture the microphone (AAudio input, 48 kHz mono 16-bit)? Records [seconds] (default 3) and prints
 * the peak/RMS per half second. Plan: microphone for iOS (Android captures, a ring carries it to /dev/redwood-mic).
 *   micprobe [seconds]      (run as root in Android; the microphone is only open while it runs)
 */
#include <aaudio/AAudio.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

int
main(int argc, char **argv)
{
	int seconds = argc > 1 ? atoi(argv[1]) : 3;
	AAudioStreamBuilder *b;
	AAudioStream *s;
	aaudio_result_t r;
	static int16_t buf[24000];
	long total = 0, win = 0;
	int peak = 0;
	double sq = 0;

	setvbuf(stdout, NULL, _IONBF, 0);
	if ((r = AAudio_createStreamBuilder(&b)) != AAUDIO_OK) {
		printf("createStreamBuilder %d\n", r);
		return 1;
	}
	AAudioStreamBuilder_setDirection(b, AAUDIO_DIRECTION_INPUT);
	AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_I16);
	AAudioStreamBuilder_setChannelCount(b, 1);
	AAudioStreamBuilder_setSampleRate(b, 48000);
	AAudioStreamBuilder_setPerformanceMode(b, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
	AAudioStreamBuilder_setInputPreset(b, AAUDIO_INPUT_PRESET_UNPROCESSED);
	if ((r = AAudioStreamBuilder_openStream(b, &s)) != AAUDIO_OK) {
		printf("openStream failed: %d (%s)\n", r, AAudio_convertResultToText(r));
		return 2;
	}
	printf("opened: rate %d, channels %d, format %d, burst %d frames\n", AAudioStream_getSampleRate(s), AAudioStream_getChannelCount(s),
	       AAudioStream_getFormat(s), AAudioStream_getFramesPerBurst(s));
	if ((r = AAudioStream_requestStart(s)) != AAUDIO_OK) {
		printf("start failed: %d (%s)\n", r, AAudio_convertResultToText(r));
		return 3;
	}
	while (total < 48000L * seconds) {
		aaudio_result_t n = AAudioStream_read(s, buf, 2400, 200 * 1000000LL);

		if (n < 0) {
			printf("read error %d (%s)\n", n, AAudio_convertResultToText(n));
			break;
		}
		for (int i = 0; i < n; i++) {
			int v = buf[i] < 0 ? -buf[i] : buf[i];

			peak = v > peak ? v : peak;
			sq += (double)buf[i] * buf[i];
		}
		total += n;
		win += n;
		if (win >= 24000) {
			printf("t=%.1fs peak %d rms %.0f\n", total / 48000.0, peak, sqrt(sq / win));
			win = 0;
			peak = 0;
			sq = 0;
		}
	}
	printf("done: %ld frames\n", total);
	AAudioStream_requestStop(s);
	AAudioStream_close(s);
	return 0;
}
