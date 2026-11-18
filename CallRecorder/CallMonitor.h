#import <Foundation/Foundation.h>

// 自动录音监听器：监听电话(CoreTelephony + CallKit)状态，接通自动录、挂断自动停。
// 微信来电无法在沙盒内监听（官方靠注入微信的 tweak），此监听器只负责系统电话/FaceTime。
@interface CallMonitor : NSObject

+ (instancetype)shared;
- (void)start;
- (void)stop;

@property (nonatomic, assign) BOOL autoRecordEnabled;   // 总开关，存 NSUserDefaults
@property (nonatomic, readonly) BOOL phoneCallActive;
@property (nonatomic, copy) void (^onCallStateChange)(NSString *state);  // 状态文案回调

@end
