#import "AppCallMonitor.h"
#import "RecorderEngine.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import <sys/sysctl.h>
#import <sys/types.h>

// ============================================================
// v9 —— 官方免费版配方：按「真实进程 PID」做 app-tap
// ------------------------------------------------------------
// 源码依据（trc_src 开源 CLI + 官方 IPA 逆向字符串）：
//   * ATAudioTapDescription.h:  initTapInternalWithFormat:PIDs:  ← PIDs 是数组
//   * 官方 CLI 只塞 -2/-3 虚拟 PID；闭源 TRRealtimeRecorder 有 _tapPID，
//     TRCallMonitor 有 populateCallAttributes:...recordingClientPIDs:（复数）
//     → 官方免费版录微信/QQ 是把「这些 App 的真实进程 PID」喂给 tap。
//   * 权限 com.apple.coreaudio.app-tap = 按进程 tap 音频流（entitlements 已具备）。
//   * v9 真机日志更正：app 真实 PID 那一路几乎全程 0，真正出声的是 -2 系统混音。
//     所以「VoIP 不经过 -2」的推断不成立；-2 仍是对方声音的主路，app-tap 只作补充。
//
// 设计：
//   1. sysctl(KERN_PROC_ALL) 枚举进程，只抓微信/QQ 主进程 PID（v9.1 排除扩展/Widget/QQMusic）。
//   2. 把这些 PID 一次性传给 initTapInternalWithFormat:PIDs:（官方同款）。
//   3. 「装上即用」：App 一启动就常驻录音，不做任何通话检测（本机已证实通知类信号全失效）。
//   4. 麦克风路 -3、真实PID路 app-tap、-2 系统混音路 三路并行，按累计峰值择优。
//   5. 出文件：采集回调里 Float32→Int16 直接写标准 PCM WAV，不经 AAC/CAF/混音。
//   6. ★v9.4：本机私有 tap 队列「回调有触发但 buffer 恒为 0 字节」（不推流），
//      因此主路改用与「单点开始录音」相同的标准麦克风 AudioQueue（真机已验证出声）。
//   7. ★v9.5 架构级修正（用户反馈「第一个通话有文件、后面没有」「时零时不灵」）：
//      旧版每 60 秒 stop/start 整个引擎并反复激活/停用 AVAudioSession；且
//      rotateSegment 的 `if (!isRecording) return` 一旦引擎被手动按钮 / 来电通知 /
//      通知栏按钮停掉，就永久不再重启。
//      本版：启动一次后队列与会话全程不重启，文件在采集回调内部按帧滚动
//      （.part → .wav，只换 FILE*），并加每 5 秒看门狗：
//        ① 引擎不在跑 → 立即重建；② 回调数 5 秒不增长 → 判队列卡死并重建。
//      手动 / 来电 / 通知栏三条路径全部隔离，不再触碰常驻录音。
// 不注入、不脱壳、不依赖任何会失效的通知 API。
// ============================================================

static NSString * const kThirdPartyAutoKey = @"CallRecorderThirdPartyAuto";
static NSString * const kLogName = @"appcall_monitor.log";
static const NSInteger kKeepSegments = 30;            // 保留最近30段(约30分钟)

#pragma mark - 进程枚举（真实 PID）

// 抓出微信/QQ 及其扩展进程的真实 PID。p_comm 在 iOS 上被截断为 16 字符
// （用户日志里的 WeChatNotificati / WeChatWidgetExte 就是这么来的），用前缀匹配。
static NSArray<NSNumber *> *FindCallAppPIDs(NSArray<NSString *> **outNames) {
    NSMutableArray<NSNumber *> *pids = [NSMutableArray array];
    NSMutableArray<NSString *>  *names = [NSMutableArray array];

    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) {
        if (outNames) *outNames = names;
        return pids;
    }
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) { if (outNames) *outNames = names; return pids; }
    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) {
        free(procs); if (outNames) *outNames = names; return pids;
    }
    int n = (int)(size / sizeof(struct kinfo_proc));
    for (int i = 0; i < n; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        const char *comm = procs[i].kp_proc.p_comm;
        if (pid <= 0 || !comm) continue;
        NSString *nm = [NSString stringWithUTF8String:comm] ?: @"";
        NSString *low = nm.lowercaseString;
        // v9.1：只保留微信/QQ 主进程。真机日志证实 v9 把通知扩展、Widget、
        // QQMusic 等 7 个无关进程一起塞进 PIDs 数组，会稀释 app-tap 的输出。
        BOOL helper = [low containsString:@"notific"]
                   || [low containsString:@"widget"]
                   || [low containsString:@"extension"]
                   || [low containsString:@"music"]
                   || [low containsString:@"share"]
                   || [low containsString:@"today"];
        BOOL hit = !helper && ([low hasPrefix:@"wechat"]   // WeChat 主进程
                            || [low hasPrefix:@"mobileqq"] // MobileQQ
                            || [low hasPrefix:@"qq"]);     // QQ 主进程
        if (hit) {
            [pids addObject:@(pid)];
            [names addObject:[NSString stringWithFormat:@"%@(%d)", nm, pid]];
        }
    }
    free(procs);
    if (outNames) *outNames = names;
    return pids;
}

static NSString *PIDSignature(NSArray<NSNumber *> *pids) {
    NSArray *sorted = [pids sortedArrayUsingSelector:@selector(compare:)];
    return [sorted componentsJoinedByString:@","];
}

@interface AppCallMonitor ()
@property (nonatomic, strong) NSTimer *diagTimer;      // v9.5 看门狗 + 实时电平（每5秒）
@property (nonatomic, assign) NSInteger diagTick;
@property (nonatomic, assign) NSInteger lastCallbackCount;   // 看门狗：上一次回调数
@property (nonatomic, assign) NSInteger watchdogRestarts;   // 自愈次数（日志用）
@property (nonatomic, assign) BOOL interrupted;             // v9.6 系统音频中断中（来电/Siri/其他App抢麦）
@property (nonatomic, strong) NSDate *interruptBeganAt;      // v9.7 中断开始时间（日志算出通话时长）
@property (nonatomic, assign) NSInteger stallTicks;           // v9.7 回调连续不增长的次数
@property (nonatomic, assign) NSInteger failStreak;           // v9.7 连续重建失败次数
@property (nonatomic, assign) NSInteger nextRebuildTick;      // v9.7 退避：到这个 tick 才能再重建
@end

@implementation AppCallMonitor

+ (instancetype)shared {
    static AppCallMonitor *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[self alloc] init];
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        s->_thirdPartyAutoEnabled = [ud objectForKey:kThirdPartyAutoKey] ? [ud boolForKey:kThirdPartyAutoKey] : YES;
    });
    return s;
}

- (void)setThirdPartyAutoEnabled:(BOOL)on {
    _thirdPartyAutoEnabled = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kThirdPartyAutoKey];
    [self log:@"自动开关设为 %@", on ? @"开" : @"关"];
    if (on) [self startContinuousRecording];
    else [self stopContinuousRecording];
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
    if (!txt) return @"(暂无日志)";
    NSArray *lines = [txt componentsSeparatedByString:@"\n"];
    NSUInteger from = lines.count > maxLines ? lines.count - maxLines : 0;
    return [[lines subarrayWithRange:NSMakeRange(from, lines.count - from)] componentsJoinedByString:@"\n"];
}

#pragma mark - 启动

- (void)start {
    [self log:@"===== 常驻录音 v9.10 (v9.7配方 + 一通一个文件) 启动 ====="];
    [self log:@"★关键: v6.0 能自动录音 / v9.4~v9.6 不能，唯一差异是录音通道"];
    [self log:@"★v6.0: 私有tap(-2系统输出 + -3麦克风), 全程不激活AVAudioSession"];
    [self log:@"★v9.4+: 标准麦克风队列 + setActive:YES → 微信/QQ通话把会话抢走, 回调恒为0"];
    [self log:@"★v9.7: 回到 v6.0 配方(双tap + 不激活会话), 主路-2出文件, 副路-3只测电平"];
    [self log:@"★v9.10: 只把『每60秒一段』改成『一通一个文件』, 采集与写盘代码与v9.7完全一致"];
    [self log:@"★另修: 中断结束后必须重建队列(旧版只打'队列仍在继续使用', 队列从此不回调)"];
    [self log:@"★另修: 发声判定改用0.1秒块能量(旧版逐采样比较, 人声过零点大量漏检→永不建文件)"];
    [self log:@"不注入/不脱壳, 装上即用, 一通电话一个WAV(静音60秒收尾), 留最近%ld个", (long)kKeepSegments];

    NSArray<NSString *> *names = nil;
    NSArray<NSNumber *> *pids = FindCallAppPIDs(&names);
    (void)PIDSignature(pids);   // 仅记录，v9.5 不再用 PID 建 tap
    [self log:@"进程扫描(仅记录): %@", names.count ? [names componentsJoinedByString:@","] : @"(微信/QQ 未运行)"];

    if (self.thirdPartyAutoEnabled) [self startContinuousRecording];
    else [self log:@"自动开关关闭, 未启动录音"];

    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(onAppActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(onAppBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    // v9.6 ★关键：系统音频中断。打电话 / 微信语音 / Siri / 别的 App 抢麦克风时，
    // 系统的采集队列会被打断并停止回调。旧版没有监听，看门狗只看到"回调不增长"，
    // 于是每 5 秒 stop+重建一次，而中断期间重建必然失败 —— 表现为通话中"时零时不灵"、
    // 挂断后要等很久才恢复。现在中断期间不重建，等中断结束立刻恢复。
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(onAudioInterrupted:) name:AVAudioSessionInterruptionNotification object:nil];

    // 每 5 秒：看门狗自愈 + 实时电平 + 定期清理旧段
    self.diagTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                      target:self selector:@selector(diagTick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.diagTimer forMode:NSRunLoopCommonModes];
}

- (void)diagTick:(NSTimer *)t {
    RecorderEngine *eng = [RecorderEngine shared];
    // v9.7：用主路(-2 系统输出)回调数判活 —— 通话中麦克风可能被独占，
    // 但系统输出 tap 才是"有没有录到通话"的真实指标。
    NSInteger cb = [eng primaryCallbackCount];
    self.diagTick++;

    // v9.6：系统音频中断期间不要去碰队列 —— 此时重建必定失败，只会刷日志
    if (self.interrupted) {
        if (self.diagTick % 2 == 0)
            [self log:@"[中断] 系统音频被占用中，暂停看门狗（等中断结束自动恢复）"];
        return;
    }

    // ★看门狗 1：自动开关开着但引擎没在跑 → 立即重建（旧版就是死在这里）
    if (self.thirdPartyAutoEnabled && !eng.isRecording) {
        [self log:@"[看门狗] 引擎已停止 → 立即重建常驻录音"];
        self.lastCallbackCount = 0;
        self.stallTicks = 0;
        [self startContinuousRecording];
        return;
    }

    // ★v9.7 看门狗 2：主路回调不增长就重建。
    // 旧版条件 `lastCallbackCount > 0` 有个坑：重建失败后 lastCallbackCount 被清成 0，
    // 于是"0 → 0"永远满足不了 `cb == lastCallbackCount && lastCallbackCount > 0`，
    // 卡死检测直接失效，只能等 5 秒后的"引擎已停止"分支去救，白等一轮。
    // 现在：连续 2 个 tick（约 4 秒）都不增长就判定卡死，且 0→0 也判卡死。
    // 另外加了失败退避：连续重建失败时逐步拉长间隔，避免"每2秒重建一次全失败"空转刷屏。
    if (self.thirdPartyAutoEnabled) {
        if (cb == self.lastCallbackCount) {
            self.stallTicks++;
        } else {
            self.stallTicks = 0;
            self.lastCallbackCount = cb;
            self.failStreak = 0;
            self.nextRebuildTick = 0;
        }
        BOOL backoffOK = (self.diagTick >= self.nextRebuildTick);
        if (self.stallTicks >= 2 && backoffOK) {
            self.watchdogRestarts++;
            [self log:@"[看门狗] 主路回调连续%ld次无增长(回调=%ld, 队列卡死) → 停止并重建 第%ld次",
                  (long)self.stallTicks, (long)cb, (long)self.watchdogRestarts];
            [eng stop];
            self.lastCallbackCount = 0;
            self.stallTicks = 0;
            BOOL ok = [self startContinuousRecordingReturningOK];
            if (!ok) {
                // 退避：第1次失败等2个tick，第2次4个，第3次起8个（约16秒一次）
                self.failStreak++;
                NSInteger wait = MIN(8, (NSInteger)pow(2, MIN(self.failStreak, 3)));
                self.nextRebuildTick = self.diagTick + wait;
                [self log:@"[看门狗] 重建失败(连续%ld次) → 退避%ld个周期后再试",
                      (long)self.failStreak, (long)wait];
            }
            return;
        }
    }

    if (!eng.isRecording) { [self log:@"[实时] 未录音(自动开关关闭)"]; return; }
    float mic = 0, app = 0, sys = 0;
    [eng consumeAutoLevelsMic:&mic app:&app sys:&sys];
    // v9.7 两路分开显示：-2 是主路(通话声音在这里)，-3 是副路(自己)
    [self log:@"[实时] 主路-2=%.4f 副路-3=%.4f 回调 主%ld/副%ld | 段=%ld 段内%.1f秒 %@",
          sys, mic,
          (long)[eng sysCallbackCount], (long)[eng micCallbackCount],
          (long)[eng currentSegmentIndex], [eng currentSegmentSeconds],
          (sys > 0.01 || mic > 0.01) ? @"★有声音" : @"(静音/环境音)"];
    if (![eng sysChannelAlive]) [self log:@"[实时] ⚠ 主路 -2 没建起来，本次录音只有麦克风"];

    if (self.diagTick % 24 == 0) [self cleanupOldSegments];
}

- (void)onAppActive:(NSNotification *)n {
    RecorderEngine *eng = [RecorderEngine shared];
    [self log:@"App回到前台 | 常驻录音=%@ 回调=%ld 自愈%ld次",
          eng.isRecording ? @"Y" : @"N", (long)[eng callbackCount], (long)self.watchdogRestarts];
}
- (void)onAppBackground:(NSNotification *)n {
    RecorderEngine *eng = [RecorderEngine shared];
    [self log:@"App进入后台 | 常驻录音=%@ 回调=%ld (队列持续, 请勿强制杀后台)",
          eng.isRecording ? @"Y" : @"N", (long)[eng callbackCount]];
}

// v9.6 系统音频中断：来电 / 微信语音 / Siri / 其他 App 抢麦克风。
// 中断期间采集队列不再回调，看门狗会误判"卡死"并反复重建（重建必失败）——
// 这就是「通话时录音时零时不灵」的机制。改为：中断期间挂起看门狗，中断一结束立刻重建。
- (void)onAudioInterrupted:(NSNotification *)n {
    NSDictionary *info = n.userInfo;
    AVAudioSessionInterruptionType type =
        (AVAudioSessionInterruptionType)[info[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        self.interrupted = YES;
        self.interruptBeganAt = [NSDate date];
        [self log:@"[中断] ⚠ 系统音频被占用（来电/语音/Siri）→ 暂停看门狗，保住在录的段"];
    } else {
        self.interrupted = NO;
        RecorderEngine *eng = [RecorderEngine shared];
        BOOL shouldResume = NO;
        NSNumber *opt = info[AVAudioSessionInterruptionOptionKey];
        if (opt) shouldResume = ([opt unsignedIntegerValue] & AVAudioSessionInterruptionOptionShouldResume) != 0;
        NSTimeInterval dur = self.interruptBeganAt ? [[NSDate date] timeIntervalSinceDate:self.interruptBeganAt] : 0;
        [self log:@"[中断] ✅ 中断结束(shouldResume=%d, 持续%.0f秒) → 重建常驻录音", shouldResume, dur];
        if (self.thirdPartyAutoEnabled) {
            // ★v9.7 决定性修复：中断期间 iOS 会把 AudioQueue 置为「已暂停」，
            // 中断结束后【必须重新 AudioQueueStart】否则队列永久不回调。
            // 旧版在这里写的是「队列仍在，继续使用（回调=N）」然后什么都不做 ——
            // 真机日志里回调数从 35 到 35 到 35 一动不动，整通电话一个字节都没录到。
            // 更糟的是：tap 通道的 AudioQueue 一旦被中断暂停，几乎不可能"恢复原队列"，
            // 唯一可靠做法是整条重建（全新 queue + 全新 tap）。
            if (eng.isRecording) {
                [self log:@"[中断] 队列已被系统暂停 → 停止并重建（旧队列不会再回调）"];
                [eng stop];
            }
            self.lastCallbackCount = 0;
            // 立刻重建，不等看门狗 5 秒
            [self startContinuousRecording];
        }
    }
}

#pragma mark - 持续录音控制

- (void)startContinuousRecording {
    (void)[self startContinuousRecordingReturningOK];
}

// v9.7：需要知道成功与否，用于看门狗退避
- (BOOL)startContinuousRecordingReturningOK {
    RecorderEngine *eng = [RecorderEngine shared];
    if (eng.isRecording) return YES;   // 单队列常驻，绝不重复启动

    NSDateFormatter *fmt = [NSDateFormatter new]; fmt.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *name = [NSString stringWithFormat:@"rec_%@.wav", [fmt stringFromDate:[NSDate date]]];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSURL *url = [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:name]];

    NSError *err = nil;
    BOOL ok = [eng startContinuousWithFileURL:url error:&err];
    self.lastCallbackCount = 0;
    [self log:@"▶ 常驻录音启动=%@ %@ | 主路=-2系统输出 副路=-3麦克风 (与v6.0同配方, 不激活会话) (基础名 %@)",
          ok ? @"成功" : @"失败", err.localizedDescription ?: @"", name];
    return ok;
}

// v9.7 语义变化：v9.7 走私有 tap，不激活会话，所以「系统中断」对我们的采集影响很小。
// 但 tap 的 AudioQueue 被系统暂停后不会自己恢复，所以中断期间不主动重建（避免失败刷屏），
// 中断结束由 onAudioInterrupted 立即重建。这里只在没有未处理中断时兜底拉起。
- (void)ensureContinuousRecording {
    if (!self.thirdPartyAutoEnabled) return;
    RecorderEngine *eng = [RecorderEngine shared];
    if (eng.isRecording) return;
    [self log:@"[保障] 常驻录音不在跑 → 拉起重开"];
    self.lastCallbackCount = 0;
    self.stallTicks = 0;
    [self startContinuousRecording];
}

- (void)stopContinuousRecording {
    RecorderEngine *eng = [RecorderEngine shared];
    if (eng.isRecording) {
        [self log:@"⏹ 关闭自动开关 → 停止常驻录音并封存当前段"];
        [eng stop];
    }
    self.lastCallbackCount = 0;
}

// v9.6：常驻录音只在启动时读一次 quality，改档位不重启就永远不生效。
// 用户切档位后调用这里：封存当前段 → 用新采样率重新开一个队列。
- (void)restartContinuousRecording {
    if (!self.thirdPartyAutoEnabled) return;
    RecorderEngine *eng = [RecorderEngine shared];
    [self log:@"⟳ 采样率改为 %ld Hz → 封存当前段并重建常驻录音",
          (long)[eng outputSampleRate]];
    if (eng.isRecording) [eng stop];
    self.lastCallbackCount = 0;
    [self startContinuousRecording];
}

- (void)cleanupOldSegments {
    @try {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docs error:nil];
        NSMutableArray *recs = [NSMutableArray array];
        for (NSString *f in files) {
            if ([f hasPrefix:@"rec_"] && ([f hasSuffix:@".wav"] || [f hasSuffix:@".m4a"])) {
                NSString *full = [docs stringByAppendingPathComponent:f];
                NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:nil];
                [recs addObject:@{@"path":full, @"date":attr[NSFileCreationDate] ?: [NSDate date]}];
            }
        }
        if (recs.count > kKeepSegments) {
            [recs sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [a[@"date"] compare:b[@"date"]];
            }];
            for (NSInteger i = 0; i < recs.count - kKeepSegments; i++) {
                [[NSFileManager defaultManager] removeItemAtPath:recs[i][@"path"] error:nil];
            }
            [self log:@"🧹 清理旧录音 %ld 个, 保留最近%ld段", (long)(recs.count - kKeepSegments), (long)kKeepSegments];
        }
    } @catch (NSException *e) { [self log:@"清理异常: %@", e.reason]; }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.diagTimer invalidate];
    [[RecorderEngine shared] stopMonitoring];
}

@end
