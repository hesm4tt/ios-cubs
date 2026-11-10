/* Settings-only presentation fallback for About rows backed by private APIs. */
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL inAbout(UIView *view)
{
    for (UIResponder *r=view; r; r=r.nextResponder) {
        if ([r isKindOfClass:[UIViewController class]]) {
            UIViewController *c=(UIViewController *)r;
            if ([c.title isEqualToString:@"About"] || [c.navigationItem.title isEqualToString:@"About"]) return YES;
        }
    }
    return NO;
}

@interface UITableViewCell (CubsAboutDisplay)
- (void)cubs_about_layoutSubviews;
@end

@implementation UITableViewCell (CubsAboutDisplay)
- (void)cubs_about_layoutSubviews
{
    [self cubs_about_layoutSubviews];
    NSString *key=self.textLabel.text, *value=nil;
    if ([key isEqualToString:@"Model Name"]) value=@"Pixel 11";
    else if ([key isEqualToString:@"Model Number"]) value=@"ported by mattv4";
    else if ([key isEqualToString:@"Serial Number"]) value=@"hesm4tt/ios-cubs";
    if (!value || !inAbout(self)) return;
    UILabel *detail=self.detailTextLabel;
    if (detail && ![detail.text isEqualToString:value]) {
        detail.adjustsFontSizeToFitWidth=YES;
        detail.minimumScaleFactor=0.65;
        detail.text=value;
    }
}
@end

__attribute__((constructor)) static void installAboutDisplay(void)
{
    Method original=class_getInstanceMethod([UITableViewCell class],@selector(layoutSubviews));
    Method replacement=class_getInstanceMethod([UITableViewCell class],@selector(cubs_about_layoutSubviews));
    if (original && replacement) method_exchangeImplementations(original,replacement);
}
