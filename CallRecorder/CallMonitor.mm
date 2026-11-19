#import "CallMonitor.h"
#import <CallKit/CallKit.h>
#import <CoreTelephony/CTCallCenter.h>
#import <CoreTelephony/CTCall.h>

// 自动录音触发器。
// 两条监听路径（与官方 TRCallMonitor 一致）：
//  1) CallKit CXCallObserver —— 系统电话 + FaceTime + 走 CallKit 的 VoIP
//  2) CoreTelephony CTCallCenter —— 传统电话（部分机型/系统仍有效）
// 检测"已接通"→ 通知 UI 开始录音；"已结束"→ 通知停止。
// 微信语音不走 CallKit，无法在此捕获（官方靠注入微信进程的 dylib 实现）。

@interface CallMonitor () <CXCallObserverDelegate>
@property (nonatomic, strong) CXCallObserver *callObserver;
@property (nonatomic, strong) CTCallCenter *ctCenter;
@property (nonatomic, assign, readwrite) BOOL phoneCallActive;
@end

@implementation CallMonitor

+ (instancetype)shared {
    static CallMonitor *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [[self alloc] init]; });
    return m;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _autoRecordEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"CallRecorderAutoRecord"];
    }
    return self;
}

- (void)setAutoRecordEnabled:(BOOL)autoRecordEnabled {
    _autoRecordEnabled = autoRecordEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:autoRecordEnabled forKey:@"CallRecorderAutoRecord"];
}

- (void)start {
    if (!_callObserver) {
        _callObserver = [CXCallObserver new];
        [_callObserver setDelegate:self queue:dispatch_get_main_queue()];
    }
    if (!_ctCenter) {
        _ctCenter = [CTCallCenter new];
        __weak typeof(self) wf = self;
        [_ctCenter setCallEventHandler:^(CTCall *call) {
            NSString *s = call.callState;
            NSLog(@"[CallMonitor] CT callState=%@", s);
            if ([s isEqualToString:CTCallStateConnected]) {
                [wf callDidBecomeActive:@"电话接通"];
            } else if ([s isEqualToString:CTCallStateDisconnected]) {
                [wf callDidEnd:@"电话结束"];
            }
        }];
    }
}

- (void)stop {
    [_callObserver setDelegate:nil queue:nil];
    _callObserver = nil;
    _ctCenter.callEventHandler = nil;
    _ctCenter = nil;
}

#pragma mark - CallKit

- (void)callObserver:(CXCallObserver *)callObserver callChanged:(CXCall *)call {
    BOOL hasConnected = call.hasConnected;
    BOOL hasEnded = call.hasEnded;
    BOOL outgoing = call.outgoing;
    NSLog(@"[CallMonitor] CX call: connected=%d ended=%d outgoing=%d count=%lu",
          hasConnected, hasEnded, outgoing, (unsigned)callObserver.calls.count);

    if (hasConnected && !hasEnded) {
        [self callDidBecomeActive:outgoing ? @"拨出接通" : @"来电接通"];
    } else if (hasEnded) {
        // 只有当前没有其它活跃通话时才停止
        BOOL anyActive = NO;
        for (CXCall *c in callObserver.calls) {
            if (c.hasConnected && !c.hasEnded) { anyActive = YES; break; }
        }
        if (!anyActive) [self callDidEnd:@"通话结束"];
    }
}

#pragma mark - 事件分发

- (void)callDidBecomeActive:(NSString *)state {
    if (self.phoneCallActive) return;   // 防重复
    self.phoneCallActive = YES;
    if (self.onCallStateChange) self.onCallStateChange(state);
    if (!self.autoRecordEnabled) return;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CallRecorderAutoStart" object:self];
}

- (void)callDidEnd:(NSString *)state {
    if (!self.phoneCallActive) return;
    self.phoneCallActive = NO;
    if (self.onCallStateChange) self.onCallStateChange(state);
    // 即使总开关关了，若之前自动开了也要发停止（UI 侧判断是否真在录）
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CallRecorderAutoStop" object:self];
}

@end
