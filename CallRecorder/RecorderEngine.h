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
