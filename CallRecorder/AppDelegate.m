#import "AppDelegate.h"
#import "ViewController.h"
#import "CallMonitor.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    ViewController *vc = [[ViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];

    // 启动来电监听（电话/FaceTime），自动录音开关由用户在设置里控制
    [[CallMonitor shared] start];
    return YES;
}

@end
