#import "AppDelegate.h"
#import "ViewController.h"
#import "CallMonitor.h"
#import "ManualControl.h"
#import "DarwinMonitor.h"

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
    // 手动录音助手：注册通知 category + 代理（尽早，保证后台点击能响应）
    [[ManualControl shared] setup];
    // 微信通话自动录音：监听 hook dylib 发出的 Darwin 通知
    [[DarwinMonitor shared] start];
    return YES;
}

// 通知在前台时也显示横幅
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    if (@available(iOS 14.0, *)) {
        completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound | UNNotificationPresentationOptionBadge);
    } else {
        completionHandler(UNNotificationPresentationOptionAlert | UNNotificationPresentationOptionSound | UNNotificationPresentationOptionBadge);
    }
}

// 用户点了通知上的"开始/停止录音"按钮（微信/QQ 通话时无需切回 App）
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    [[ManualControl shared] handleAction:response.actionIdentifier];
    completionHandler();
}

@end
