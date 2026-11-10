/*
 * hello: the smallest self-contained UIKit app, for the sideload test (nothing but UIKit: the MetalDemo clone used before needs libmtlshim and
 * died at load in the test image). An orange screen with a big text; also writes /tmp/hello.log so a job can show that it ran.
 *   xnu-clang -arch arm64 -isysroot $THEOS/sdks/iPhoneOS16.5.sdk -fno-objc-arc -O1 -framework Foundation -framework UIKit -o PersistTest hello.m
 */
#import <UIKit/UIKit.h>

@interface HApp : UIResponder <UIApplicationDelegate>
@property (nonatomic, retain) UIWindow *window;
@end

@implementation HApp

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts
{
	FILE *f = fopen("/tmp/hello.log", "a");

	if (f != NULL) {
		fprintf(f, "hello: launched\n");
		fclose(f);
	}
	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	UIViewController *vc = [[UIViewController alloc] init];

	vc.view.backgroundColor = [UIColor orangeColor];
	UILabel *l = [[UILabel alloc] initWithFrame:vc.view.bounds];

	l.text = @"SIDELOAD OK";
	l.textAlignment = NSTextAlignmentCenter;
	l.font = [UIFont boldSystemFontOfSize:48];
	l.textColor = [UIColor blackColor];
	[vc.view addSubview:l];
	self.window.rootViewController = vc;
	[self.window makeKeyAndVisible];
	return YES;
}

@end

int
main(int argc, char **argv)
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, @"HApp");
	}
}
