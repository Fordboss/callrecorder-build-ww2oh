#import <Foundation/Foundation.h>

// 官方 TrollRecorder 同款的"第三方 App 通话"自动触发器。
// 不依赖注入 dylib：通过检测微信/QQ 进入前台 + 系统音频活动来判定通话开始/结束，
// 然后调用已有的双路系统级 tap 录音引擎（RecorderEngine, TRChannelSystemAudio）。
@interface AppCallMonitor : NSObject

+ (instancetype)shared;

// 开关（独立持久化）
@property (nonatomic, assign) BOOL thirdPartyAutoEnabled;

// 安装监听（AppDelegate didFinishLaunching 调用一次）
- (void)start;

// v9.6：改采样率档位后让常驻录音按新档位重新开始（旧版常驻模式下改档位不生效）
- (void)restartContinuousRecording;

// 诊断日志路径（ Documents/appcall_monitor.log ）
@property (nonatomic, readonly) NSURL *logURL;
- (NSString *)recentLog:(NSUInteger)maxLines;

@end
