#import "AppCallMonitor.h"
#import "RecorderEngine.h"
#import <UIKit/UIKit.h>
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
//   5. ★v9.1 保底：麦克风路在采集回调里直接写一份 AAC m4a（见 RecorderEngine），
//      不再把文件成败押在「CAF→二次打开→格式转换→混音」链路上；混音成功才升级为立体声。
//   6. PID 会随微信/QQ 重启变化 → 每 15 秒刷新，变化就切段重建 tap。
// 不注入、不脱壳、不激活 AVAudioSession、不依赖任何会失效的通知 API。
// ============================================================

static NSString * const kThirdPartyAutoKey = @"CallRecorderThirdPartyAuto";
static NSString * const kLogName = @"appcall_monitor.log";
static const NSTimeInterval kSegmentSeconds = 120.0;  // 每段2分钟（更快刷新PID/更细粒度）
static const NSInteger kKeepSegments = 30;            // 只保留最近30段(约1小时)
static const NSTimeInterval kPIDWatchSeconds = 15.0;  // PID 刷新周期

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
@property (nonatomic, strong) NSTimer *segmentTimer;
@property (nonatomic, strong) NSTimer *diagTimer;
@property (nonatomic, strong) NSTimer *pidWatchTimer;
@property (nonatomic, assign) NSInteger segmentIndex;
@property (nonatomic, assign) NSInteger diagTick;
@property (nonatomic, assign) float segmentPeak;        // 本段三路累计峰值（判静音）
@property (nonatomic, copy)   NSString *activePIDSignature;
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
    [self log:@"===== 持续录音 v9.1 (保底直写 + app-tap) 启动 ====="];
    [self log:@"配方: initTapInternalWithFormat:PIDs: ← 仅微信/QQ主进程PID, 不注入/不脱壳"];
    [self log:@"三路: 自己(-3) + 对方(真实PID) + 系统混音(-2), 停止时自动择优"];
    [self log:@"★保底: 麦克风PCM在回调里直接编码成m4a, 混音仅为立体声增强"];
    [self log:@"不激活AVAudioSession, 装上即用, 每%.0f秒一段, 每%.0f秒刷新PID", kSegmentSeconds, kPIDWatchSeconds];

    NSArray<NSString *> *names = nil;
    NSArray<NSNumber *> *pids = FindCallAppPIDs(&names);
    [self log:@"初始进程扫描: %ld个 | %@", (long)pids.count,
          names.count ? [names componentsJoinedByString:@","] : @"(微信/QQ 尚未运行, 启动后会自动刷新)"];

    if (self.thirdPartyAutoEnabled) {
        [self startContinuousRecording];
    } else {
        [self log:@"自动开关关闭, 未启动录音"];
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(onAppActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(onAppBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];

    // 三路实时诊断：每5秒一条，一眼看出哪条路抓到声音
    self.diagTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                      target:self selector:@selector(diagTick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.diagTimer forMode:NSRunLoopCommonModes];

    // PID 变化监听：微信/QQ 启动或重启后自动重建 tap，不用等切段
    self.pidWatchTimer = [NSTimer scheduledTimerWithTimeInterval:kPIDWatchSeconds
                          target:self selector:@selector(pidWatchTick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.pidWatchTimer forMode:NSRunLoopCommonModes];
}

- (void)diagTick:(NSTimer *)t {
    RecorderEngine *eng = [RecorderEngine shared];
    if (!eng.isRecording) { [self log:@"[实时] 未录音"]; return; }
    float mic = 0, app = 0, sys = 0;
    [eng consumeAutoLevelsMic:&mic app:&app sys:&sys];
    float mx = fmaxf(mic, fmaxf(app, sys));
    if (mx > self.segmentPeak) self.segmentPeak = mx;
    self.diagTick++;
    // 每 5 秒都写，方便回看通话那几秒；标注 app-tap 是否生效
    [self log:@"[实时] mic=-3:%.4f app真实PID:%.4f sys混音:%.4f %@ | appTap=%@ | PID集=%@",
          mic, app, sys, mx > 0.01 ? @"★有声音" : @"(静音)",
          eng.appTapActive ? @"Y" : @"N", self.activePIDSignature ?: @"-"];
}

- (void)pidWatchTick:(NSTimer *)t {
    NSArray<NSNumber *> *pids = FindCallAppPIDs(NULL);
    NSString *sig = PIDSignature(pids);
    if (self.activePIDSignature && ![sig isEqualToString:self.activePIDSignature]) {
        [self log:@"♻ PID 变化: [%@] → [%@], 立即切段重建 app-tap", self.activePIDSignature, sig];
        [self rotateSegment];
    }
}

- (void)onAppActive:(NSNotification *)n {
    [self log:@"App回到前台 | 录音中=%@ 第%ld段 appTap=%@",
          [RecorderEngine shared].isRecording ? @"Y" : @"N", (long)self.segmentIndex,
          [RecorderEngine shared].appTapActive ? @"Y" : @"N"];
}
- (void)onAppBackground:(NSNotification *)n {
    [self log:@"App进入后台 | 录音中=%@ (双路tap持续, 请勿强制杀后台)",
          [RecorderEngine shared].isRecording ? @"Y" : @"N"];
}

#pragma mark - 持续录音控制

- (void)startContinuousRecording {
    if ([[RecorderEngine shared] isRecording]) {
        [self log:@"已在录音, 忽略重复启动"];
        return;
    }
    self.segmentIndex++;
    self.segmentPeak = 0;

    NSDateFormatter *fmt = [NSDateFormatter new]; fmt.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *name = [NSString stringWithFormat:@"rec_%@.m4a", [fmt stringFromDate:[NSDate date]]];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSURL *url = [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:name]];

    // ★核心：把微信/QQ 真实 PID 喂给 tap
    NSArray<NSString *> *names = nil;
    NSArray<NSNumber *> *pids = FindCallAppPIDs(&names);
    self.activePIDSignature = PIDSignature(pids);
    [self log:@"▶ 第%ld段 %@ | app-tap 目标PID(%ld): %@", (long)self.segmentIndex, name,
          (long)pids.count, names.count ? [names componentsJoinedByString:@","] : @"(空→引擎回退-2)"];

    NSError *err = nil;
    BOOL ok = [[RecorderEngine shared] startAutoWithAppPIDs:pids fileURL:url error:&err];
    [self log:@"   启动=%@ app-tap已创建=%@ %@", ok ? @"成功" : @"失败",
          [RecorderEngine shared].appTapActive ? @"Y(该路是否有声音看实时电平)" : @"N(回退系统混音)",
          err.localizedDescription ?: @""];

    [self.segmentTimer invalidate];
    self.segmentTimer = [NSTimer scheduledTimerWithTimeInterval:kSegmentSeconds
                         target:self selector:@selector(rotateSegment) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.segmentTimer forMode:NSRunLoopCommonModes];

    if (!ok) {
        __weak typeof(self) wf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (wf.thirdPartyAutoEnabled && ![[RecorderEngine shared] isRecording]) [wf startContinuousRecording];
        });
    }
}

- (void)rotateSegment {
    if (![[RecorderEngine shared] isRecording]) return;
    RecorderEngine *eng = [RecorderEngine shared];
    [self log:@"⏱ 第%ld段结束 | 本段峰值=%.4f → %@ | appTap=%@",
          (long)self.segmentIndex, self.segmentPeak,
          self.segmentPeak > 0.01 ? @"★有声音(可能含通话)" : @"(静音/底噪)",
          eng.appTapActive ? @"Y" : @"N"];

    [eng stop];   // 同步混音保存 m4a（内部自动择优）
    [self cleanupOldSegments];

    __weak typeof(self) wf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (wf.thirdPartyAutoEnabled && ![[RecorderEngine shared] isRecording]) [wf startContinuousRecording];
    });
}

- (void)stopContinuousRecording {
    [self.segmentTimer invalidate]; self.segmentTimer = nil;
    if ([[RecorderEngine shared] isRecording]) {
        [self log:@"⏹ 停止录音 | 本段峰值=%.4f", self.segmentPeak];
        [[RecorderEngine shared] stop];
    }
}

- (void)cleanupOldSegments {
    @try {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docs error:nil];
        NSMutableArray *recs = [NSMutableArray array];
        for (NSString *f in files) {
            if ([f hasPrefix:@"rec_"] && [f hasSuffix:@".m4a"]) {
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
    [self.segmentTimer invalidate];
    [self.diagTimer invalidate];
    [self.pidWatchTimer invalidate];
    [[RecorderEngine shared] stopMonitoring];
}

@end
