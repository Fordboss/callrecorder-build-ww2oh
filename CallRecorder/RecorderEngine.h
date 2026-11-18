#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, TRChannel) {
    TRChannelSystemAudio = 0,   // 系统音频（对方+自己，通话录音用这个）
    TRChannelMicrophone  = 1,   // 麦克风
    TRChannelSpeaker     = 2,   // 扬声器
};

typedef NS_ENUM(NSInteger, TRQuality) {
    TRQualitySmall  = 0,        // 16 kHz  / 32 kbps  约 0.24 MB/分钟
    TRQualityNormal = 1,        // 22.05 kHz / 64 kbps 约 0.48 MB/分钟
    TRQualityHigh   = 2,        // 44.1 kHz / 96 kbps  约 0.72 MB/分钟
};

@interface RecorderEngine : NSObject

+ (instancetype)shared;

- (BOOL)startWithChannel:(TRChannel)channel
                 fileURL:(NSURL *)fileURL
                   error:(NSError **)error;
- (void)stop;

@property (nonatomic, readonly) BOOL isRecording;
@property (nonatomic, assign) TRQuality quality;                 // 运行时可改，下次录音生效
@property (nonatomic, readonly) NSInteger outputSampleRate;      // 当前档位采样率
@property (nonatomic, readonly) NSURL *debugLogURL;              // 诊断日志路径

+ (NSString *)qualityDescription:(TRQuality)q;

@end
