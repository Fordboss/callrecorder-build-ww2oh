#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, TRChannel) {
    TRChannelSystemAudio = 0,   // 系统音频（对方+自己，通话录音用这个）
    TRChannelMicrophone = 1,    // 麦克风
    TRChannelSpeaker = 2,       // 扬声器
};

@interface RecorderEngine : NSObject

+ (instancetype)shared;

- (BOOL)startWithChannel:(TRChannel)channel
                   fileURL:(NSURL *)fileURL
                     error:(NSError **)error;
- (void)stop;

@property (nonatomic, readonly) BOOL isRecording;

@end
