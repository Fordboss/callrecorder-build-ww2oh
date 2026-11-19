#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, TRChannel) {
    TRChannelSystemAudio = 0,   // 双路：麦克风(自己)+扬声器(对方) 混音 —— 通话录音用这个
    TRChannelMicrophone  = 1,   // 仅麦克风
    TRChannelSpeaker     = 2,   // 仅扬声器/听筒
};

// 输出音质：混音时重采样到该采样率 + AAC 编码 → 小体积
typedef NS_ENUM(NSInteger, TRQuality) {
    TRQualitySmall  = 0,   // 16 kHz    ≈ 0.25 MB/分钟
    TRQualityNormal = 1,   // 22.05 kHz ≈ 0.35 MB/分钟
    TRQualityHigh   = 2,   // 44.1 kHz  ≈ 0.6 MB/分钟
};

@protocol RecorderEngineDelegate <NSObject>
@optional
- (void)recorderDidFinishWithURL:(NSURL *)url micLevel:(float)micLevel speakerLevel:(float)spkLevel;
- (void)recorderDidFailWithMessage:(NSString *)msg;
@end

@interface RecorderEngine : NSObject

+ (instancetype)shared;

// 双路录音：麦克风 + 扬声器同时采集为两路 CAF，停止时自动混音为 m4a
// channel: TRChannelSystemAudio=双路混音；Microphone/Speaker=单路
- (BOOL)startWithChannel:(TRChannel)channel
                 fileURL:(NSURL *)fileURL          // 最终输出 .m4a 路径
                   error:(NSError **)error;
- (void)stop;                                       // 停止并混音，结果走 delegate

// v9 核心：按微信/QQ「真实进程 PID」做 app-tap（官方免费版录第三方 App 的配方）。
//  - 自己(麦克风)：PID -3，一直可用
//  - 对方(微信/QQ 播放的语音)：不再用 -2 系统混音，改用 appPIDs 里的真实进程 PID
//  - 同时开一路 -2 系统混音「监测通道」(不写盘，只报电平)，用于诊断哪条路有声音
//  - appPIDs 为空 / 真实 PID tap 创建失败 → 自动回退 -2，保证至少有一路
//  - 采样率档位 (quality) 在停止混音时生效，与上面所有版本一致
- (BOOL)startAutoWithAppPIDs:(NSArray<NSNumber *> *)appPIDs
                     fileURL:(NSURL *)fileURL
                       error:(NSError **)error;

// v9.5 ★常驻录音：启动一次后队列与 AVAudioSession 全程不重启，
// 回调内部每 60 秒滚动出一个可直接播放的 WAV（.part → .wav）。
// 只有关闭自动开关 / App 退出才 stop。
- (BOOL)startContinuousWithFileURL:(NSURL *)fileURL error:(NSError **)error;
// 看门狗用：采集回调累计次数（每 5 秒不增长即判为队列卡死）
@property (nonatomic, readonly) NSInteger callbackCount;
// v9.7 看门狗用主路(-2 系统输出)回调数判活，比两路之和更准确
@property (nonatomic, readonly) NSInteger primaryCallbackCount;
@property (nonatomic, readonly) NSInteger sysCallbackCount;   // -2 系统输出回调数（诊断）
@property (nonatomic, readonly) NSInteger micCallbackCount;   // -3 麦克风回调数（诊断）
@property (nonatomic, readonly) BOOL sysChannelAlive;         // -2 主路是否建起来了
@property (nonatomic, readonly) BOOL micChannelAlive;         // -3 副路是否建起来了
// v9.6 界面用：常驻录音「当前第几段」与「本段已录秒数」
// （旧版界面完全不知道常驻录音在跑，按钮永远停在"开始录音"）
// 返回 0 表示正在待机（还没检测到人声，磁盘上什么都没建）
- (NSInteger)currentSegmentIndex;
- (double)currentSegmentSeconds;
// 已经封存落盘的通话段数（界面上可以显示"今天录到 N 段"）
- (NSInteger)sealedSegmentCount;
// 界面专用麦克风电平（自带衰减，不受看门狗清零影响）
- (float)uiMicLevel;
// v9.7 界面专用：主路(-2 系统输出) / 副路(-3 麦克风) 各自电平，自带衰减
- (float)uiSystemLevel;
- (float)uiMicOnlyLevel;
@property (nonatomic, readonly) float appLevel;      // 对方路(app-tap)电平
@property (nonatomic, readonly) float systemLevel;   // 系统混音(-2)监测电平（诊断用）
@property (nonatomic, readonly) BOOL  appTapActive;  // 是否成功用上真实 PID tap
// 取三路实时电平并清零（每 5 秒诊断：哪条路真的抓到声音）
- (void)consumeAutoLevelsMic:(float *)mic app:(float *)app sys:(float *)sys;

@property (nonatomic, weak)   id<RecorderEngineDelegate> delegate;
@property (nonatomic, readonly) BOOL isRecording;
@property (nonatomic, assign) TRQuality quality;                 // 运行时可改，下次录音生效
@property (nonatomic, readonly) NSInteger outputSampleRate;      // 当前档位采样率
@property (nonatomic, readonly) NSURL *debugLogURL;
@property (nonatomic, readonly) float peakLevel;                 // 综合电平（兼容旧 UI）
@property (nonatomic, readonly) float micLevel;                  // 麦克风（自己）电平
@property (nonatomic, readonly) float speakerLevel;              // 扬声器（对方）电平

// 监测模式：常驻开 tap 只算电平不写盘，用于检测微信/QQ 通话是否有音频活动。
// 触发录音前应 stopMonitoring，避免同 PID 两路 tap 冲突。
- (BOOL)startMonitoringWithError:(NSError **)error;
- (void)stopMonitoring;
@property (nonatomic, readonly) BOOL isMonitoring;
@property (nonatomic, readonly) float monitorMicLevel;      // 监测-麦克风电平
@property (nonatomic, readonly) float monitorSpeakerLevel;  // 监测-扬声器电平
// 取监测电平并清零（避免 peak 只增不减导致无法判断声音停止）
- (void)consumeMonitorLevelsMic:(float *)mic speaker:(float *)spk;

+ (NSString *)qualityDescription:(TRQuality)q;
@end
