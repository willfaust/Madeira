#import <UIKit/UIKit.h>
#include "SignedFEX.h"
#include "JITAllocator.h"
#include <unistd.h>
#include <sys/utsname.h>

extern int csops(pid_t, unsigned int, void *, size_t);
bool jit_cs_status(uint32_t *flags)
{
    uint32_t value = 0;
    if (csops(getpid(), 0, &value, sizeof(value))) return false;
    *flags = value;
    return true;
}

@interface MadeiraFEXDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation MadeiraFEXDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options
{
    (void)application; (void)options;
    setenv("MADEIRA_SIGNED_FEX", "1", 1);
    madeira_signed_fex_if_requested();
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *report = [documents URLByAppendingPathComponent:@"signed-fex.txt"];
    NSString *text = [NSString stringWithContentsOfURL:report encoding:NSUTF8StringEncoding error:NULL] ?: @"FAIL: no report.\n";
    struct utsname machine;
    uname(&machine);
    NSString *source = [NSBundle.mainBundle objectForInfoDictionaryKey:@"MadeiraFEXSourceID"] ?: @"unknown";
    NSString *evidence = [NSString stringWithFormat:@"source-id=%@\ndevice=%s os=%@\n%@", source,
        machine.machine, UIDevice.currentDevice.systemVersion, text];
    [evidence writeToURL:report atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSLog(@"[signed-fex-device] %@", evidence);
    return YES;
}
@end

@interface MadeiraFEXScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation MadeiraFEXScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    (void)session; (void)options;
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSString *report = [NSString stringWithContentsOfURL:[documents URLByAppendingPathComponent:@"signed-fex.txt"]
        encoding:NSUTF8StringEncoding error:NULL] ?: @"No report.";
    NSString *summary = [report containsString:@"PASS: six complete"] ? @"Six program runs passed" : @"Program run needs review";
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    UITextView *text = [UITextView new];
    text.editable = NO;
    text.selectable = YES;
    text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    text.adjustsFontForContentSizeCategory = YES;
    text.textColor = UIColor.labelColor;
    text.backgroundColor = UIColor.systemBackgroundColor;
    text.text = [NSString stringWithFormat:@"Madeira signed FEX\n%@\n\n%@", summary, report];
    text.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:text];
    UILayoutGuide *safe = controller.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [text.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [text.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
        [text.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [text.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20]
    ]];
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
}
@end

int main(int argc, char **argv)
{
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(MadeiraFEXDelegate.class)); }
}
