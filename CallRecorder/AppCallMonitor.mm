#import "AppCallMonitor.h"
#import "RecorderEngine.h"
#import <AVFoundation/AVAudioSession.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

// ============================================================
// 官方 TrollRecorder 同款思路：不注入第三方 App，靠"前台 App + 系统音频活动"
// 判定微信/QQ 通话开始/结束，然后调用已有的双路系统级 tap 录音引擎。
//
// 触发信号（多层，任一命中即可，全部做存在性防护）：
//   1) AVAudioSessionInterruption —— 微信/QQ 通话建立时会中断其它 App 的音频会话
//   2) 前台 App bundle id —— 用私有 API 读 SpringBoard 的 frontmost app
//   3) 音频会话 category/mode 变化轮询兜底
// 所有私有 API 都通过 NSClassFromString/performSelector/dlsym 动态调用，
// 拿不到就自动降级，绝不崩溃。全程写日志便于真机校准。
// ============================================================

static NSString * const kThirdPartyAutoKey = @"CallRecorderThirdPartyAuto";
static NSString * const kLogName = @"appcall_monitor.log";

// 识别的通话 App（bundle id → 显示名）
static NSDictionary<NSString *, NSString *> *CallApps(void) {
    return @{
        @"com.tencent.xin":        @"微信",
        @"com.tencent.mobileqq":   @"QQ",
        @"com.tencent.mobileqqhd": @"QQ HD",
        @"com.tencent.wework":     @"企业微信",
    };
}

@interface AppCallMonitor ()
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, copy)   NSString *currentCallApp;   // 当前判定为通话中的 App bundle
@property (nonatomic, assign) BOOL inCall;
@end

@implementation AppCallMonitor

+ (instancetype)shared {
    static AppCallMonitor *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[self alloc] init];
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        s.thirdPartyAutoEnabled = [ud objectForKey:kThirdPartyAutoKey] ? [ud boolForKey:kThirdPartyAutoKey] : YES;
    });
    return s;
}

- (void)setThirdPartyAutoEnabled:(BOOL)thirdPartyAutoEnabled {
    _thirdPartyAutoEnabled = thirdPartyAutoEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:thirdPartyAutoEnabled forKey:kThirdPartyAutoKey];
    [self log:@"自动开关设为 %@", thirdPartyAutoEnabled ? @"开" : @"关"];
}

#pragma mark - 日志

- (NSURL *)logURL {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:kLogName]];
}

- (void)log:(NSString *)fmt, ... {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], body];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:self.logURL.path];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [[line dataUsingEncoding:NSUTF8StringEncoding] writeToFile:self.logURL.path atomically:YES]; }
    NSLog(@"[AppCall] %@", body);
}

- (NSString *)recentLog:(NSUInteger)maxLines {
    NSString *txt = [NSString stringWithContentsOfURL:self.logURL encoding:NSUTF8StringEncoding error:nil];
    if (!txt) return @"(暂无日志，先打一通微信/QQ电话)";
    NSArray *lines = [txt componentsSeparatedByString:@"\n"];
    NSUInteger from = lines.count > maxLines ? lines.count - maxLines : 0;
    return [[lines subarrayWithRange:NSMakeRange(from, lines.count - from)] componentsJoinedByString:@"\n"];
}

#pragma mark - 私有 API：读前台 App bundle id（多重兜底）

// 方法 A：SpringBoard 的 frontmost app（私有但跨版本稳定）
- (NSString *)frontmostViaSpringBoard {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        SEL sel = NSSelectorFromString(@"_accessibilityFrontMostApplication");
        if (![app respondsToSelector:sel]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id frontApp = [app performSelector:sel];
#pragma clang diagnostic pop
        if (!frontApp) return nil;
        if ([frontApp respondsToSelector:@selector(bundleIdentifier)]) {
            return [frontApp performSelector:@selector(bundleIdentifier)];
        }
    } @catch (NSException *e) {
        [self log:@"frontmostViaSpringBoard 异常: %@", e.reason];
    }
    return nil;
}

// 方法 B：BKSApplicationStateMonitor 拿前台 app（官方同款私有类）
- (NSString *)frontmostViaBKS {
    @try {
        Class BKSClass = NSClassFromString(@"BKSApplicationStateMonitor");
        if (!BKSClass) return nil;
        id monitor = [[BKSClass alloc] init];
        if (!monitor) return nil;
        // 枚举 application states 字典，找 BKSApplicationStateKeyIsFrontmost = YES
        SEL stateSel = NSSelectorFromString(@"applicationStates");
        if (![monitor respondsToSelector:stateSel]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSDictionary *states = [monitor performSelector:stateSel];
#pragma clang diagnostic pop
        for (NSNumber *pid in states) {
            NSDictionary *st = states[pid];
            id front = st[@"BKSApplicationStateKeyIsFrontmost"];
            if ([front boolValue]) {
                return st[@"BKSApplicationStateKeyBundleIdentifier"] ?: st[@"bundleIdentifier"];
            }
        }
    } @catch (NSException *e) {
        [self log:@"frontmostViaBKS 异常: %@", e.reason];
    }
    return nil;
}

- (NSString *)currentFrontmostBundle {
    NSString *b = [self frontmostViaSpringBoard];
    if (b) return b;
    b = [self frontmostViaBKS];
    if (b) return b;
    return nil;
}

#pragma mark - 启动

- (void)start {
    [self log:@"===== AppCallMonitor 启动 (免注入检测) ====="];

    // 1) 音频会话中断通知：微信/QQ 通话建立会中断其他 App 音频 → 即时触发
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(onAudioInterruption:)
        name:AVAudioSessionInterruptionNotification object:nil];
    [self log:@"已监听 AVAudioSessionInterruptionNotification"];

    // 2) 音频会话激活我们的会话（后台保活，也需要它才能收到 interruption）
    @try {
        AVAudioSession *ses = [AVAudioSession sharedInstance];
        [ses setCategory:AVAudioSessionCategoryPlayAndRecord
                    mode:AVAudioSessionModeVoiceChat
                 options:AVAudioSessionCategoryOptionMixWithOthers |
                         AVAudioSessionCategoryOptionAllowBluetooth |
                         AVAudioSessionCategoryOptionDefaultToSpeaker
                   error:nil];
        [ses setActive:YES error:nil];
        [self log:@"音频会话已激活 PlayAndRecord/VoiceChat (category=%@ mode=%@)",
              ses.category, ses.mode];
    } @catch (NSException *e) {
        [self log:@"音频会话激活异常: %@", e.reason];
    }

    // 3) 前台轮询兜底（0.5s）
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                       target:self selector:@selector(poll:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];

    // 4) 应用回到前台时立即检查一次
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(onAppActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
}

#pragma mark - 信号回调

- (void)onAppActive:(NSNotification *)n {
    NSString *b = [self currentFrontmostBundle];
    [self log:@"App 回到前台, frontmost=%@", b ?: @"(无法读取)"];
}

- (void)onAudioInterruption:(NSNotification *)n {
    NSNumber *typeNum = n.userInfo[AVAudioSessionInterruptionTypeKey];
    AVAudioSessionInterruptionType type = (AVAudioSessionInterruptionType)typeNum.unsignedIntegerValue;
    NSString *b = [self currentFrontmostBundle];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        [self log:@"★音频中断 BEGAN (可能有通话开始), frontmost=%@", b ?: @"?"];
        if ([self isCallApp:b]) {
            [self log:@"中断+前台确认为通话App(%@) → 尝试开始录音", CallApps()[b]];
            [self maybeStartForApp:b];
        }
    } else if (type == AVAudioSessionInterruptionTypeEnded) {
        [self log:@"音频中断 ENDED, frontmost=%@", b ?: @"?"];
        // 结束不立即停，交给轮询确认（对方短暂静音也会触发 ended）
    }
}

- (BOOL)isCallApp:(NSString *)bundle {
    return bundle && CallApps()[bundle] != nil;
}

#pragma mark - 轮询判定

- (void)poll:(NSTimer *)t {
    NSString *b = [self currentFrontmostBundle];
    BOOL isCall = [self isCallApp:b];

    if (isCall) {
        if (!self.inCall || ![b isEqualToString:self.currentCallApp]) {
            [self log:@"轮询判定: 通话App进入前台 %@(%@)", b, CallApps()[b]];
            [self maybeStartForApp:b];
        }
    } else {
        if (self.inCall) {
            // 离开通话 App，延迟 1.2s 确认（防切到微信看消息瞬间误停）
            [self performSelector:@selector(confirmEndIfStillNotCall)
                       withObject:nil afterDelay:1.2];
        }
    }
}

- (void)confirmEndIfStillNotCall {
    NSString *b = [self currentFrontmostBundle];
    if ([self isCallApp:b]) return;  // 又回来了，取消停止
    [self maybeStop];
}

#pragma mark - 录音控制

- (void)maybeStartForApp:(NSString *)bundle {
    if (!self.thirdPartyAutoEnabled) { [self log:@"自动开关关闭, 不启动"]; return; }
    if ([RecorderEngine shared].isRecording) { [self log:@"已在录音, 忽略"]; return; }

    self.currentCallApp = bundle;
    self.inCall = YES;

    // 延时等音频路由稳定（官方也是事件后延迟启动）
    __weak typeof(self) wf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!wf.inCall) return;
        if ([RecorderEngine shared].isRecording) return;
        NSDateFormatter *fmt = [NSDateFormatter new]; fmt.dateFormat = @"yyyyMMdd_HHmmss";
        NSString *label = CallApps()[wf.currentCallApp] ?: @"app";
        NSString *name = [NSString stringWithFormat:@"auto_%@_%@.m4a", label, [fmt stringFromDate:[NSDate date]]];
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSURL *url = [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:name]];
        NSError *err = nil;
        BOOL ok = [[RecorderEngine shared] startWithChannel:TRChannelSystemAudio fileURL:url error:&err];
        [wf log:@"→ 启动双路录音 %@: %@ %@", ok ? @"成功" : @"失败", name, err.localizedDescription ?: @""];
    });
}

- (void)maybeStop {
    if (!self.inCall) return;
    if (![RecorderEngine shared].isRecording) {
        self.inCall = NO; self.currentCallApp = nil;
        return;
    }
    self.inCall = NO;
    [self log:@"→ 通话结束, 停止并保存"];
    [[RecorderEngine shared] stop];
    self.currentCallApp = nil;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.pollTimer invalidate];
}

@end
