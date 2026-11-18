#import "AppCallMonitor.h"
#import "RecorderEngine.h"
#import <AVFoundation/AVAudioSession.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <math.h>

// ============================================================
// 微信/QQ 通话自动触发 —— 官方 TrollRecorder 同款多路信号探测版
// 不注入、不脱壳。三层信号，任一命中即触发；每层都有详细日志。
//   A) AVSystemController NowPlaying App 变化（微信通话会变 NowPlaying）
//   B) MediaRemote NowPlaying 通知（dlsym 官方同款私有函数）
//   C) sysctl 枚举进程 + proc_pidpath 判断微信/QQ 是否在运行
//   D) 前台 App（BKS / accessibility，尽力而为，读不到不致命）
// 微信/QQ bundle 与进程名双重识别；命中后调 RecorderEngine 双路录音。
// 所有私有 API 动态调用 + @try 防护，拿不到就降级，绝不崩溃。
// ============================================================

static NSString * const kThirdPartyAutoKey = @"CallRecorderThirdPartyAuto";
static NSString * const kLogName = @"appcall_monitor.log";

static NSDictionary<NSString *, NSString *> *CallApps(void) {
    return @{
        @"com.tencent.xin":        @"微信",
        @"com.tencent.mobileqq":   @"QQ",
        @"com.tencent.mobileqqhd": @"QQHD",
        @"com.tencent.wework":     @"企业微信",
    };
}
// 进程名（proc_pidpath 末段）→ bundle
static NSString *BundleFromProcName(NSString *proc) {
    NSString *p = [proc lowercaseString];
    if ([p containsString:@"wechat"]) return @"com.tencent.xin";
    if ([p containsString:@"mobileqq"] || [p isEqualToString:@"qq"]) return @"com.tencent.mobileqq";
    return nil;
}

@interface AppCallMonitor ()
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, copy)   NSString *currentCallApp;
@property (nonatomic, assign) BOOL inCall;
@property (nonatomic, assign) NSInteger hitCount;
@property (nonatomic, assign) NSInteger audioHitTicks;   // 电平命中连续次数
@property (nonatomic, assign) NSInteger audioSilentTicks;
@property (nonatomic, assign) NSInteger diagTick;        // 诊断计数
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

- (void)setThirdPartyAutoEnabled:(BOOL)on {
    _thirdPartyAutoEnabled = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kThirdPartyAutoKey];
    [self log:@"自动开关设为 %@", on ? @"开" : @"关"];
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

#pragma mark - 启动

- (void)start {
    [self log:@"===== AppCallMonitor v2 启动 (多路信号) ====="];

    // A) AVSystemController NowPlaying App 变化（官方 TRApp 用这套）
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(onNowPlayingAppChange:)
        name:@"AVSystemController_NowPlayingAppDidChangeNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(onNowPlayingAppChange:)
        name:@"AVSystemController_NowPlayingAppIsPlayingDidChangeNotification" object:nil];
    [self log:@"[A] 已监听 AVSystemController NowPlaying 通知"];

    // B) MediaRemote 通知（dlsym 官方同款）
    [self setupMediaRemote];

    // C) 音频会话中断（辅助）
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(onAudioInterruption:)
        name:AVAudioSessionInterruptionNotification object:nil];
    [self log:@"[C] 已监听 AVAudioSessionInterruptionNotification"];

    // D) 激活音频会话（后台保活 + 收中断；MixWithOthers 不干扰微信）
    @try {
        AVAudioSession *ses = [AVAudioSession sharedInstance];
        [ses setCategory:AVAudioSessionCategoryPlayAndRecord
                    mode:AVAudioSessionModeDefault
                 options:AVAudioSessionCategoryOptionMixWithOthers
                   error:nil];
        [ses setActive:YES error:nil];
        [self log:@"[D] 音频会话激活: category=%@ mode=%@", ses.category, ses.mode];
    } @catch (NSException *e) { [self log:@"[D] 音频会话异常: %@", e.reason]; }

    // 启动常驻电平监测（核心：不依赖任何通知，有声音就检测得到）
    NSError *merr = nil;
    BOOL monOK = [[RecorderEngine shared] startMonitoringWithError:&merr];
    [self log:@"[E] 电平监测启动 %@ %@", monOK ? @"成功" : @"失败", merr.localizedDescription ?: @""];

    // 轮询（0.25s）—— 电平 + 信号综合判定
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                       target:self selector:@selector(poll:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];

    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(onAppActive:) name:UIApplicationDidBecomeActiveNotification object:nil];

    [self log:@"[C] 初始进程探测: %@", [self runningCallAppsDescription]];
}

#pragma mark - B) MediaRemote

- (void)setupMediaRemote {
    @try {
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (!h) { [self log:@"[B] MediaRemote dlopen 失败: %s", dlerror()]; return; }
        [self log:@"[B] MediaRemote dlopen 成功"];

        void (*setWants)(BOOL) = (void (*)(BOOL))dlsym(h, "MRMediaRemoteSetWantsNowPlayingNotifications");
        if (setWants) { setWants(YES); [self log:@"[B] SetWantsNowPlayingNotifications(YES) OK"]; }
        else [self log:@"[B] 找不到 MRMediaRemoteSetWantsNowPlayingNotifications"];

        CFStringRef *npRef = (CFStringRef *)dlsym(h, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification");
        NSString *npName = npRef && *npRef ? (__bridge NSString *)(*npRef) : @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification";
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onNowPlayingAppChange:) name:npName object:nil];
        [self log:@"[B] 已监听 MediaRemote NowPlaying 通知: %@", npName];
    } @catch (NSException *e) { [self log:@"[B] MediaRemote 异常: %@", e.reason]; }
}

#pragma mark - 信号回调

- (void)onAppActive:(NSNotification *)n {
    [self log:@"App 回到前台 | 进程探测: %@", [self runningCallAppsDescription]];
}

- (void)onNowPlayingAppChange:(NSNotification *)n {
    NSString *bundle = nil;
    NSDictionary *ui = n.userInfo;
    if (ui) {
        for (NSString *key in ui) {
            id v = ui[key];
            NSString *s = [v isKindOfClass:[NSString class]] ? v : [v description];
            if ([s containsString:@"tencent"]) { bundle = s; break; }
        }
        [self log:@"[A/B] NowPlaying通知 %@ userInfo=%@", n.name, ui];
    } else {
        [self log:@"[A/B] NowPlaying通知 %@ (无userInfo)", n.name];
    }
    if ([self isCallApp:bundle]) {
        [self log:@"[A/B] ★NowPlaying 命中通话App %@(%@)", bundle, CallApps()[bundle]];
        [self maybeStartForApp:bundle];
    } else {
        NSString *fromProc = [self runningCallApp];
        if (fromProc) { [self log:@"[A/B] NowPlaying变化 + 进程命中 %@ → 触发", fromProc]; [self maybeStartForApp:fromProc]; }
    }
}

- (void)onAudioInterruption:(NSNotification *)n {
    NSNumber *typeNum = n.userInfo[AVAudioSessionInterruptionTypeKey];
    AVAudioSessionInterruptionType type = (AVAudioSessionInterruptionType)typeNum.unsignedIntegerValue;
    NSUInteger opts = [n.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
    [self log:@"[C] 音频中断 type=%@ opts=%lu | 进程:%@",
          type == AVAudioSessionInterruptionTypeBegan ? @"BEGAN" : @"ENDED",
          (unsigned long)opts, [self runningCallAppsDescription]];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        NSString *app = [self runningCallApp] ?: [self frontmostCallApp];
        if (app) { [self log:@"[C] ★中断+命中 %@ → 触发", app]; [self maybeStartForApp:app]; }
        else [self log:@"[C] 中断来了但没识别到微信/QQ进程，仅记录"];
    }
}

#pragma mark - C) 进程探测（核心）

- (NSArray<NSString *> *)runningWeChatQQProcNames {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        size_t size = 0;
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
        if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return out;
        struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
        if (!procs) return out;
        if (sysctl(mib, 4, procs, &size, NULL, 0) == 0) {
            int n = (int)(size / sizeof(struct kinfo_proc));
            for (int i = 0; i < n; i++) {
                // iOS 上用 kp_proc.p_comm 拿进程名（最多16字符，如 WeChat / MobileQQ）
                char *comm = procs[i].kp_proc.p_comm;
                if (comm[0]) {
                    NSString *pname = [NSString stringWithUTF8String:comm];
                    if (BundleFromProcName(pname) && ![out containsObject:pname]) [out addObject:pname];
                }
            }
        }
        free(procs);
    } @catch (NSException *e) { [self log:@"[C] 进程探测异常: %@", e.reason]; }
    return out;
}

- (NSString *)runningCallApp {
    for (NSString *proc in [self runningWeChatQQProcNames]) {
        NSString *b = BundleFromProcName(proc);
        if (b) return b;
    }
    return nil;
}

- (NSString *)runningCallAppsDescription {
    NSArray *a = [self runningWeChatQQProcNames];
    return a.count ? [a componentsJoinedByString:@","] : @"(无微信/QQ进程)";
}

#pragma mark - D) 前台读取（尽力而为，读不到不致命）

- (NSString *)frontmostCallApp {
    NSString *b = [self frontmostViaBKS];
    if ([self isCallApp:b]) return b;
    b = [self frontmostViaAccessibility];
    if ([self isCallApp:b]) return b;
    return nil;
}

- (NSString *)frontmostViaAccessibility {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        SEL sel = NSSelectorFromString(@"_accessibilityFrontMostApplication");
        if (![app respondsToSelector:sel]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id front = [app performSelector:sel];
#pragma clang diagnostic pop
        if ([front respondsToSelector:@selector(bundleIdentifier)])
            return [front performSelector:@selector(bundleIdentifier)];
    } @catch (NSException *e) {}
    return nil;
}

- (NSString *)frontmostViaBKS {
    @try {
        Class BKSClass = NSClassFromString(@"BKSApplicationStateMonitor");
        if (!BKSClass) return nil;
        id monitor = [[BKSClass alloc] init];
        SEL stateSel = NSSelectorFromString(@"applicationStateForBundleIdentifier:");
        for (NSString *bundle in CallApps()) {
            if ([monitor respondsToSelector:stateSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id st = [monitor performSelector:stateSel withObject:bundle];
#pragma clang diagnostic pop
                // BKSApplicationStateFrontmost = 4
                if ([st isKindOfClass:[NSNumber class]] && [st unsignedIntegerValue] == 4) return bundle;
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

#pragma mark - 轮询

// 电平阈值：Float32 PCM，语音通常峰值 0.02~0.3；0.01 过滤底噪
static const float kLevelThreshold = 0.012f;

- (void)poll:(NSTimer *)t {
    self.diagTick++;

    // 1) 读监测电平（并清零）。录音进行中读的是录音通道电平。
    float mic = 0, spk = 0;
    if ([[RecorderEngine shared] isMonitoring]) {
        [[RecorderEngine shared] consumeMonitorLevelsMic:&mic speaker:&spk];
    } else if ([[RecorderEngine shared] isRecording]) {
        mic = [RecorderEngine shared].micLevel;
        spk = [RecorderEngine shared].speakerLevel;
    }
    float peak = fmaxf(mic, spk);
    BOOL hasSound = peak > kLevelThreshold;

    // 2) 每 5 秒打一次诊断（把电平打出来，能直接看出微信通话时有没有声音进来）
    if (self.diagTick % 20 == 0) {
        [self log:@"[诊断] mic=%.4f spk=%.4f 有声=%@ | 进程:%@ | 录音中=%@",
              mic, spk, hasSound?@"Y":@"N", [self runningCallAppsDescription],
              [[RecorderEngine shared] isRecording]?@"Y":@"N"];
    }

    // 3) 未在录音：电平触发
    if (![[RecorderEngine shared] isRecording]) {
        // 音频活动命中时，优先确认微信/QQ进程在（降低误触发）；进程读不到就用纯电平
        NSString *procApp = [self runningCallApp];
        if (hasSound) {
            self.audioHitTicks++;
            self.audioSilentTicks = 0;
            // 连续 6 次(1.5s)有声音 → 判定通话
            if (self.audioHitTicks >= 6) {
                NSString *app = procApp ?: @"微信";  // 读不到进程名就先默认按微信触发
                [self log:@"[E] ★电平触发(连续%ld次有声音, mic=%.3f spk=%.3f) app=%@",
                      (long)self.audioHitTicks, mic, spk, app];
                self.audioHitTicks = 0;
                [self triggerRecordForApp:app];
            }
        } else {
            self.audioSilentTicks++;
            if (self.audioSilentTicks > 8) self.audioHitTicks = 0;  // 静音2s清零累计
        }
    }
    // 4) 录音中：检测挂断（持续静音 ~6s）
    else if (self.inCall) {
        if (hasSound) {
            self.audioSilentTicks = 0;
        } else {
            self.audioSilentTicks++;
            if (self.audioSilentTicks >= 24) {  // 6s 静音 → 挂断
                [self log:@"[E] 录音中持续静音6s → 判定挂断, 停止"];
                self.audioSilentTicks = 0;
                [self stopRecordAndResumeMonitor];
            }
        }
    }
}

// 触发录音：先停监测，再开正式录音
- (void)triggerRecordForApp:(NSString *)bundle {
    if (!self.thirdPartyAutoEnabled) { [self log:@"自动开关关闭, 不启动"]; return; }
    if ([[RecorderEngine shared] isRecording]) return;
    [[RecorderEngine shared] stopMonitoring];
    self.currentCallApp = bundle;
    self.inCall = YES;

    NSDateFormatter *fmt = [NSDateFormatter new]; fmt.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *label = CallApps()[bundle] ?: @"微信";
    NSString *name = [NSString stringWithFormat:@"auto_%@_%@.m4a", label, [fmt stringFromDate:[NSDate date]]];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSURL *url = [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:name]];
    NSError *err = nil;
    BOOL ok = [[RecorderEngine shared] startWithChannel:TRChannelSystemAudio fileURL:url error:&err];
    [self log:@"→ 电平触发双路录音 %@: %@ %@", ok?@"成功":@"失败", name, err.localizedDescription ?: @""];
    if (!ok) {
        // 启动失败，恢复监测
        NSError *merr = nil;
        [[RecorderEngine shared] startMonitoringWithError:&merr];
        self.inCall = NO;
    }
}

- (void)stopRecordAndResumeMonitor {
    self.inCall = NO;
    if ([[RecorderEngine shared] isRecording]) {
        [self log:@"→ 挂断, 停止并保存, 恢复监测"];
        [[RecorderEngine shared] stop];
    }
    // 延迟恢复监测（等混音完成）
    __weak typeof(self) wf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([RecorderEngine shared].isRecording) return;
        NSError *merr = nil;
        BOOL ok = [[RecorderEngine shared] startMonitoringWithError:&merr];
        [wf log:@"→ 监测恢复 %@ %@", ok?@"OK":@"FAIL", merr.localizedDescription ?: @""];
    });
}

- (void)confirmEndIfStillNotCall { [self stopRecordAndResumeMonitor]; }

// 通知型信号（NowPlaying/中断）到来时的加速触发，统一走电平验证后的录音路径。
// 注意：这些信号在部分设备不来，所以只是加速，主触发仍靠 poll 里的电平检测。
- (void)maybeStartForApp:(NSString *)bundle {
    [self log:@"[信号] 收到通知型触发 %@（若设备收不到属正常，靠电平兜底）", bundle];
    // 不立即录音，交给 poll 的电平检测确认真的有声音，避免误触发
}

- (void)maybeStop { [self stopRecordAndResumeMonitor]; }

- (BOOL)isCallApp:(NSString *)bundle { return bundle && CallApps()[bundle] != nil; }

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.pollTimer invalidate];
    [[RecorderEngine shared] stopMonitoring];
}

@end
