#import "AppCallMonitor.h"
#import "RecorderEngine.h"
#import <UIKit/UIKit.h>
#import <math.h>

// ============================================================
// 持续录音模式 v1（对标官方免费版"后台常驻录音"）
// ------------------------------------------------------------
// 设计原则（这次不再做通话检测，因为检测信号在用户设备全部失效）：
//   1. 启动即全程双路录音（麦克风 -3 + 扬声器 -2），微信/QQ/电话通话声音都录进去。
//   2. 定时切段（默认5分钟一个文件），只保留最近 N 段，避免无限占空间。
//   3. 每段记录 mic/spk 电平峰值到日志——用户打完电话一看就知道哪段有声音、录没录到。
//   4. ★不激活 AVAudioSession★：官方 call-recorder.mm 和用户 v5 手动录音
//      （已验证能录到微信通话）都是纯净 tap，靠 CanRecordWithoutSessionActivation 权限。
//      v8.1 曾激活 mode:Default session，极可能破坏 tap 导致电平全 0。这次彻底去掉。
// 不注入、不脱壳、不依赖任何会失效的通知/前台/MediaRemote API。
// ============================================================

static NSString * const kThirdPartyAutoKey = @"CallRecorderThirdPartyAuto";
static NSString * const kLogName = @"appcall_monitor.log";
static const NSTimeInterval kSegmentSeconds = 300.0;   // 每段5分钟
static const NSInteger kKeepSegments = 24;             // 只保留最近24段(约2小时)

@interface AppCallMonitor ()
@property (nonatomic, strong) NSTimer *segmentTimer;
@property (nonatomic, strong) NSTimer *diagTimer;
@property (nonatomic, assign) NSInteger segmentIndex;
@property (nonatomic, assign) NSInteger diagTick;
@end

@implementation AppCallMonitor

+ (instancetype)shared {
    static AppCallMonitor *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[self alloc] init];
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        // 直接设 ivar，不触发开关副作用（开关副作用只在用户手动切换/start 时发生）
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
    [self log:@"===== 持续录音模式 v1 启动 ====="];
    [self log:@"原理: 不做通话检测, App保持运行即全程双路录音, 每%.0f分钟自动存一个文件", kSegmentSeconds/60];
    [self log:@"注意: 不激活AVAudioSession(对齐官方call-recorder/已验证的v5纯净tap路径)"];
    if (self.thirdPartyAutoEnabled) {
        [self startContinuousRecording];
    } else {
        [self log:@"自动开关关闭, 未启动录音"];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(onAppActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(onAppBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];

    // 实时诊断：每5秒记录当前录音电平，打完电话回来看最后几行就知道录没录到
    self.diagTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                      target:self selector:@selector(diagTick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.diagTimer forMode:NSRunLoopCommonModes];
}

- (void)diagTick:(NSTimer *)t {
    if (![[RecorderEngine shared] isRecording]) {
        [self log:@"[实时] 未录音"];
        return;
    }
    float mic = [RecorderEngine shared].micLevel;
    float spk = [RecorderEngine shared].speakerLevel;
    [self log:@"[实时] mic=%.4f spk=%.4f %@", mic, spk,
          fmaxf(mic,spk) > 0.01 ? @"★有声音" : @"(静音)"];
}

- (void)onAppActive:(NSNotification *)n {
    [self log:@"App回到前台 | 录音中=%@ 当前第%ld段",
          [[RecorderEngine shared] isRecording]?@"Y":@"N", (long)self.segmentIndex];
}
- (void)onAppBackground:(NSNotification *)n {
    [self log:@"App进入后台 | 录音中=%@ (双路tap持续, 请勿强制杀后台)",
          [[RecorderEngine shared] isRecording]?@"Y":@"N"];
}

#pragma mark - 持续录音控制

- (void)startContinuousRecording {
    if ([[RecorderEngine shared] isRecording]) {
        [self log:@"已在录音, 忽略重复启动"];
        return;
    }
    self.segmentIndex++;

    NSDateFormatter *fmt = [NSDateFormatter new]; fmt.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *name = [NSString stringWithFormat:@"rec_%@.m4a", [fmt stringFromDate:[NSDate date]]];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSURL *url = [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:name]];

    NSError *err = nil;
    BOOL ok = [[RecorderEngine shared] startWithChannel:TRChannelSystemAudio fileURL:url error:&err];
    [self log:@"▶ 开始第%ld段 %@ : %@ %@", (long)self.segmentIndex, name,
          ok?@"成功":@"失败", err.localizedDescription ?: @""];

    // 定时切段（NSTimer 在后台可能被节流，最坏情况只是这段更长，不影响录到声音）
    [self.segmentTimer invalidate];
    self.segmentTimer = [NSTimer scheduledTimerWithTimeInterval:kSegmentSeconds
                         target:self selector:@selector(rotateSegment) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.segmentTimer forMode:NSRunLoopCommonModes];

    if (!ok) {
        // 启动失败：稍后重试一次
        __weak typeof(self) wf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (wf.thirdPartyAutoEnabled && ![[RecorderEngine shared] isRecording]) [wf startContinuousRecording];
        });
    }
}

- (void)rotateSegment {
    if (![[RecorderEngine shared] isRecording]) return;

    // 切段前读电平峰值并写入日志——这是判断"这段有没有录到通话"的关键证据
    float mic = [RecorderEngine shared].micLevel;
    float spk = [RecorderEngine shared].speakerLevel;
    float peak = fmaxf(mic, spk);
    [self log:@"⏱ 第%ld段结束 | 峰值 mic=%.4f spk=%.4f → %@",
          (long)self.segmentIndex, mic, spk,
          peak > 0.01 ? @"★有声音(可能含通话)" : @"(静音/底噪)"];

    [[RecorderEngine shared] stop];   // 同步混音保存 m4a
    [self cleanupOldSegments];

    // 稍等混音收尾再开下一段
    __weak typeof(self) wf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (wf.thirdPartyAutoEnabled && ![[RecorderEngine shared] isRecording]) [wf startContinuousRecording];
    });
}

- (void)stopContinuousRecording {
    [self.segmentTimer invalidate]; self.segmentTimer = nil;
    if ([[RecorderEngine shared] isRecording]) {
        float mic = [RecorderEngine shared].micLevel;
        float spk = [RecorderEngine shared].speakerLevel;
        [self log:@"⏹ 停止录音 | 峰值 mic=%.4f spk=%.4f → %@",
              mic, spk, fmaxf(mic,spk) > 0.01 ? @"★有声音" : @"(静音)"];
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
                return [a[@"date"] compare:b[@"date"]];  // 旧->新
            }];
            for (NSInteger i = 0; i < recs.count - kKeepSegments; i++) {
                [[NSFileManager defaultManager] removeItemAtPath:recs[i][@"path"] error:nil];
            }
            [self log:@"🧹 清理旧录音 %ld 个, 保留最近%ld段",
                  (long)(recs.count - kKeepSegments), (long)kKeepSegments];
        }
    } @catch (NSException *e) { [self log:@"清理异常: %@", e.reason]; }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.segmentTimer invalidate];
    [self.diagTimer invalidate];
    [[RecorderEngine shared] stopMonitoring];
}

@end
