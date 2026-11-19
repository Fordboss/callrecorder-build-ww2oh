#import <Foundation/Foundation.h>

// 录音完成时由 ViewController 发出，ManualControl 据此推送结果通知
extern NSString * const ManualRecordingDoneNotification;

@interface ManualControl : NSObject
+ (instancetype)shared;
- (void)setup;                        // didFinishLaunching 里尽早调用：注册 category + 监听完成通知
- (void)requestPermissionAndEnable;   // 请求通知权限并发出常驻控制通知
- (void)handleAction:(NSString *)identifier;  // 处理通知按钮
@end
