/*
 * mictest: does the microphone of iOS work? A small app (com.cubs.mictest, baked into /Applications) that records with AVAudioRecorder (metering on) and
 * shows the live level on the screen: a big number (peak dB), a bar, and the state; every 0.5 s a line "mictest: t=.. peak=.. avg=.." goes to
 * /tmp/mictest.log (a boot job cats it into the kernel log). Make noise near the phone's bottom microphone: the bar must move.
 *   xnu-clang -arch arm64 -isysroot $THEOS/sdks/iPhoneOS16.5.sdk -fno-objc-arc -O1 -o MicTest mictest.m -framework Foundation -framework UIKit \
 *       -framework AVFoundation -lobjc
 */
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include "libtccfake.m"   /* the same permission answers inside this app (constructor + AV swizzles) */

static void
L(NSString *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];

	va_end(ap);
	FILE *f = fopen("/tmp/mictest.log", "a");

	if (f != NULL) {
		fprintf(f, "mictest: %s\n", [s UTF8String]);
		fclose(f);
	}
}

@interface MTApp : UIResponder <UIApplicationDelegate>
@property (nonatomic, retain) UIWindow *window;
@property (nonatomic, retain) AVAudioRecorder *rec;
@property (nonatomic, retain) UILabel *state, *level;
@property (nonatomic, retain) UIView *bar;
@property (nonatomic, retain) NSTimer *timer;
@property (nonatomic, retain) AVAudioEngine *engine;
@end

@implementation MTApp {
	double _t0, _maxPeak;
	int _ticks;
	BOOL _analysed;
}

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts
{
	CGRect b = [UIScreen mainScreen].bounds;

	self.window = [[UIWindow alloc] initWithFrame:b];
	UIViewController *vc = [[UIViewController alloc] init];

	vc.view.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.3 alpha:1];
	self.state = [[UILabel alloc] initWithFrame:CGRectMake(20, 120, b.size.width - 40, 120)];
	self.state.textColor = [UIColor whiteColor];
	self.state.numberOfLines = 0;
	self.state.font = [UIFont boldSystemFontOfSize:22];
	self.state.text = @"MIC TEST starting";
	[vc.view addSubview:self.state];
	self.level = [[UILabel alloc] initWithFrame:CGRectMake(20, 260, b.size.width - 40, 90)];
	self.level.textColor = [UIColor yellowColor];
	self.level.font = [UIFont boldSystemFontOfSize:60];
	self.level.text = @"-- dB";
	[vc.view addSubview:self.level];
	self.bar = [[UIView alloc] initWithFrame:CGRectMake(20, 380, 4, 60)];
	self.bar.backgroundColor = [UIColor greenColor];
	[vc.view addSubview:self.bar];
	self.window.rootViewController = vc;
	[self.window makeKeyAndVisible];
	L(@"app started");
	[self performSelector:@selector(start) withObject:nil afterDelay:1.0];
	return YES;
}

- (void)start
{
	NSError *err = nil;
	AVAudioSession *s = [AVAudioSession sharedInstance];

	L(@"record permission: %u (granted = %u)", (unsigned)s.recordPermission, 0x67726e74u);
	[s setCategory:AVAudioSessionCategoryPlayAndRecord error:&err];
	L(@"setCategory: %@", err ? err.description : @"ok");
	err = nil;
	[s setActive:YES error:&err];
	L(@"setActive: %@", err ? err.description : @"ok");
	err = nil;
	L(@"inputAvailable=%d inputGain=%.2f sampleRate=%.0f inputChannels=%d", (int)s.isInputAvailable, s.inputGain, s.sampleRate, (int)s.inputNumberOfChannels);
	for (AVAudioSessionPortDescription *d in s.availableInputs) {
		L(@"available input: %@ (%@)", d.portName, d.portType);
	}
	for (AVAudioSessionPortDescription *d in s.currentRoute.inputs) {
		L(@"route input: %@ (%@) channels %lu", d.portName, d.portType, (unsigned long)d.channels.count);
	}
	for (AVAudioSessionPortDescription *d in s.currentRoute.outputs) {
		L(@"route output: %@ (%@)", d.portName, d.portType);
	}
	NSDictionary *settings = @{ AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @48000, AVNumberOfChannelsKey: @1,
		AVLinearPCMBitDepthKey: @16, AVLinearPCMIsFloatKey: @NO };
	self.rec = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:@"/tmp/mictest.caf"] settings:settings error:&err];
	L(@"recorder: %@", err ? err.description : @"created");
	if (self.rec == nil) {
		self.state.text = [NSString stringWithFormat:@"recorder failed:\n%@", err.localizedDescription];
		return;
	}
	self.rec.meteringEnabled = YES;
	BOOL ok = [self.rec prepareToRecord];

	L(@"prepareToRecord: %d", ok);
	ok = [self.rec record];
	L(@"record: %d", ok);
	self.state.text = ok ? @"RECORDING: make noise near the bottom microphone" : @"record failed";
	_t0 = CACurrentMediaTime();
	self.timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)analyse
{
	[self.rec stop];
	NSError *err = nil;
	AVAudioFile *f = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:@"/tmp/mictest.caf"] error:&err];

	if (f == nil) {
		L(@"file: cannot open: %@", err.description);
	} else {
		AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:f.processingFormat frameCapacity:48000];
		[f readIntoBuffer:buf error:&err];
		float peak = 0;
		for (int c = 0; c < (int)buf.format.channelCount; c++) {
			for (AVAudioFrameCount i = 0; i < buf.frameLength; i++) {
				float v = fabsf(buf.floatChannelData[c][i]);
				peak = v > peak ? v : peak;
			}
		}
		L(@"file: %lld frames, first second peak %.6f (%.1f dB)", f.length, peak, peak > 0 ? 20 * log10f(peak) : -999.0);
	}
	[self startEngine];
}

- (void)startEngine
{
	NSError *err = nil;

	self.engine = [[AVAudioEngine alloc] init];
	AVAudioInputNode *in = self.engine.inputNode;
	AVAudioFormat *fmt = [in outputFormatForBus:0];

	L(@"engine input format: %.0f Hz, %u ch", fmt.sampleRate, (unsigned)fmt.channelCount);
	__block int n = 0;
	[in installTapOnBus:0 bufferSize:4800 format:fmt block:^(AVAudioPCMBuffer *b, AVAudioTime *t) {
		float peak = 0;
		for (AVAudioFrameCount i = 0; i < b.frameLength; i++) {
			float v = fabsf(b.floatChannelData[0][i]);
			peak = v > peak ? v : peak;
		}
		if ((n++ % 5) == 0) {
			L(@"engine tap: %u frames, peak %.6f (%.1f dB)", (unsigned)b.frameLength, peak, peak > 0 ? 20 * log10f(peak) : -999.0);
		}
	}];
	BOOL ok = [self.engine startAndReturnError:&err];

	L(@"engine start: %d %@", ok, err ? err.description : @"");
}

- (void)tick
{
	if (!_analysed && CACurrentMediaTime() - _t0 > 40.0) {
		_analysed = YES;
		[self analyse];
	}
	[self.rec updateMeters];
	float peak = [self.rec peakPowerForChannel:0], avg = [self.rec averagePowerForChannel:0];
	double w = (peak + 90.0) / 90.0 * (self.window.bounds.size.width - 40);

	if (w < 4) {
		w = 4;
	}
	self.bar.frame = CGRectMake(20, 380, w, 60);
	self.level.text = [NSString stringWithFormat:@"%.0f dB", peak];
	if (peak > _maxPeak || _ticks == 0) {
		_maxPeak = peak;
	}
	if ((++_ticks % 5) == 0) {
		L(@"t=%.1f peak=%.1f avg=%.1f dB, recorder time %.1f s, recording=%d", CACurrentMediaTime() - _t0, peak, avg, self.rec.currentTime,
		  self.rec.isRecording);
	}
}

@end

int
main(int argc, char *argv[])
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([MTApp class]));
	}
}
