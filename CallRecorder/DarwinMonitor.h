#import <Foundation/Foundation.h>

// 监听微信 hook dylib (WeChatCallHook) 发出的 Darwin 通知，自动触发/停止双路录音
@interface DarwinMonitor : NSObject
+ (instancetype)shared;
- (void)start;                 // AppDelegate didFinishLaunching 里调用
@property (nonatomic, assign) BOOL wechatAutoEnabled;  // 是否启用微信通话自动录音（默认YES）
@end
