#import "DarwinMonitor.h"
#import "RecorderEngine.h"
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>

// 与 WeChatCallHook.dylib 约定的通知名
static CFStringRef const kWeChatCallStart = CFSTR("com.wb.callrecorder.wxc.start");
static CFStringRef const kWeChatCallEnd   = CFSTR("com.wb.callrecorder.wxc.end");

static NSString * const kWeChatAutoKey = @"CallRecorderWeChatAuto";
static NSString * const kLogFile = @"wechat_auto.log";

static void CRWLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [docs stringByAppendingPathComponent:kLogFile];
    NSDateFormatter *f = [[NSDateFormatter alloc] init]; f.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], body];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [[line dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES]; }
    NSLog(@"[WxAuto] %@", body);
}

// CFNotificationCenter 回调（C 函数）
static void OnWeChatCallStart(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    CRWLog(@"收到微信来电/接通通知");
    DarwinMonitor *self = (__bridge DarwinMonitor *)observer;
    if (!self.wechatAutoEnabled) { CRWLog(@"自动录音已关闭，忽略"); return; }
    if ([RecorderEngine shared].isRecording) { CRWLog(@"已在录音中，忽略重复 start"); return; }

    // 后台唤醒后短暂延时，等微信音频路由稳定
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyyMMdd_HHmmss";
        NSString *name = [NSString stringWithFormat:@"auto_wechat_%@.m4a", [fmt stringFromDate:[NSDate date]]];
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSURL *url = [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:name]];
        NSError *err = nil;
        BOOL ok = [[RecorderEngine shared] startWithChannel:TRChannelSystemAudio fileURL:url error:&err];
        CRWLog(@"触发双路录音 %@ %@", ok ? @"成功" : @"失败", err.localizedDescription ?: @"");
    });
}

static void OnWeChatCallEnd(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    CRWLog(@"收到微信挂断通知");
    if (![RecorderEngine shared].isRecording) { CRWLog(@"当前未在录音，忽略"); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CRWLog(@"停止并保存");
        [[RecorderEngine shared] stop];
    });
}

@implementation DarwinMonitor

+ (instancetype)shared {
    static DarwinMonitor *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[self alloc] init];
        BOOL on = [[NSUserDefaults standardUserDefaults] objectForKey:kWeChatAutoKey]
                  ? [[NSUserDefaults standardUserDefaults] boolForKey:kWeChatAutoKey] : YES;
        s.wechatAutoEnabled = on;
    });
    return s;
}

- (void)setWechatAutoEnabled:(BOOL)wechatAutoEnabled {
    _wechatAutoEnabled = wechatAutoEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:wechatAutoEnabled forKey:kWeChatAutoKey];
}

- (void)start {
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(center, (__bridge const void *)self, OnWeChatCallStart,
                                    kWeChatCallStart, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, (__bridge const void *)self, OnWeChatCallEnd,
                                    kWeChatCallEnd, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CRWLog(@"===== DarwinMonitor 启动，监听微信通话通知 =====");
}

- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                       (__bridge const void *)self, NULL, NULL);
}

@end
