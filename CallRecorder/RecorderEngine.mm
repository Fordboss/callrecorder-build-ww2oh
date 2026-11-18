#import "RecorderEngine.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>

#import "ATAudioTap.h"
#import "ATAudioTapDescription.h"
#import "AudioQueue+Private.h"

#pragma mark - 运行时档位（改这里 = 改默认值；App 内可切换）

// tap 采集固定用官方验证过的 44100，写入时再由 ExtAudioFile 重采样到档位采样率。
// 之前用 16000 直接 tap 在很多机型上拿不到数据，这是"录不到"的主因之一。
static const Float64 kTapSampleRate  = 44100.0;
static const int kNumberOfBuffers    = 3;
static const int kMaximumBufferSize  = 0x50000;
static const int kMinimumBufferSize  = 0x4000;

static inline Float64 SampleRateForQuality(TRQuality q) {
    switch (q) {
        case TRQualityHigh:   return 44100.0;
        case TRQualityNormal: return 22050.0;
        case TRQualitySmall:
        default:              return 16000.0;
    }
}
static inline UInt32 BitRateForQuality(TRQuality q) {
    switch (q) {
        case TRQualityHigh:   return 96000;
        case TRQualityNormal: return 64000;
        case TRQualitySmall:
        default:              return 32000;
    }
}

#pragma mark - 诊断日志（写 Documents/recorder_debug.log，供真机排查）

static NSURL *CRDebugLogURL(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:@"recorder_debug.log"]];
}
static void CRLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], body];
    NSURL *url = CRDebugLogURL();
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:url.path];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [[line dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url atomically:YES];
    }
    NSLog(@"[Recorder] %@", body);
}

#pragma mark - 引擎

@interface RecorderEngine () {
    AudioStreamBasicDescription _tapFormat;     // tap 采集格式（44100 Float32）
    AudioQueueRef               _queue;
    AudioQueueBufferRef         _buffers[kNumberOfBuffers];
    ExtAudioFileRef             _extFile;
    UInt32                      _bufferSize;
    int                         _tapPID;
    ATAudioTap                 *_audioTap;
    BOOL                        _recording;
    BOOL                        _waitingDevice;
    UInt64                      _totalBytes;
    int                         _callbackCount;
}
@end

@implementation RecorderEngine

+ (NSString *)qualityDescription:(TRQuality)q {
    switch (q) {
        case TRQualityHigh:   return @"44.1 kHz · 96 kbps · 约 0.72 MB/分钟";
        case TRQualityNormal: return @"22.05 kHz · 64 kbps · 约 0.48 MB/分钟";
        case TRQualitySmall:
        default:              return @"16 kHz · 32 kbps · 约 0.24 MB/分钟";
    }
}

+ (instancetype)shared {
    static RecorderEngine *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 从偏好读取档位，默认省空间
        NSInteger q = [[NSUserDefaults standardUserDefaults] integerForKey:@"CallRecorderQuality"];
        if (q < 0 || q > 2) q = 0;
        _quality = (TRQuality)q;
    }
    return self;
}

- (void)setQuality:(TRQuality)quality {
    _quality = quality;
    [[NSUserDefaults standardUserDefaults] setInteger:quality forKey:@"CallRecorderQuality"];
}

- (NSInteger)outputSampleRate { return (NSInteger)SampleRateForQuality(_quality); }
- (NSURL *)debugLogURL { return CRDebugLogURL(); }
- (BOOL)isRecording { return _recording; }

#pragma mark 采集回调：tap 的 PCM -> ExtAudioFile（重采样+编码 AAC）

static void RecorderCallback(void *ptr, AudioQueueRef aq, AudioQueueBufferRef buffer,
                             const AudioTimeStamp *ts, UInt32 numPackets,
                             const AudioStreamPacketDescription *packetDesc) {
    RecorderEngine *self = (__bridge RecorderEngine *)ptr;
    if (self->_extFile && buffer->mAudioDataByteSize > 0) {
        AudioBufferList list;
        list.mNumberBuffers = 1;
        list.mBuffers[0].mNumberChannels = self->_tapFormat.mChannelsPerFrame;
        list.mBuffers[0].mDataByteSize = buffer->mAudioDataByteSize;
        list.mBuffers[0].mData = buffer->mAudioData;
        UInt32 frames = buffer->mAudioDataByteSize / self->_tapFormat.mBytesPerFrame;
        OSStatus st = ExtAudioFileWrite(self->_extFile, frames, &list);
        if (st != noErr) CRLog(@"写入失败 ExtAudioFileWrite=%d frames=%u", (int)st, (unsigned)frames);
        self->_totalBytes += buffer->mAudioDataByteSize;
    }
    self->_callbackCount++;
    if (self->_callbackCount == 1) {
        CRLog(@"首个音频回调：字节=%u 通道=%u", (unsigned)buffer->mAudioDataByteSize,
              (unsigned)self->_tapFormat.mChannelsPerFrame);
    }
    if (self->_recording) AudioQueueEnqueueBuffer(aq, buffer, 0, NULL);
}

// 监听 queue 是否真的在跑；私有 tap 常见"queue 启了但没设备"，靠这个反馈
static void ListenerCallback(void *userData, AudioQueueRef queue, AudioQueuePropertyID prop) {
    RecorderEngine *self = (__bridge RecorderEngine *)userData;
    UInt32 running = 0, size = sizeof(running);
    if (AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &running, &size) == noErr) {
        CRLog(@"AudioQueue IsRunning=%u (waiting=%@)", (unsigned)running, self->_waitingDevice ? @"YES" : @"NO");
        if (running == 0 && !self->_waitingDevice) {
            self->_recording = NO;
        } else if (running != 0 && self->_waitingDevice) {
            self->_waitingDevice = NO;
            self->_recording = YES;
        }
    }
}

static void CalculateBufferSize(AudioQueueRef queue, AudioStreamBasicDescription desc, UInt32 *outSize) {
    UInt32 maxPacket = desc.mBytesPerPacket;
    if (maxPacket == 0) {
        UInt32 s = sizeof(maxPacket);
        AudioQueueGetProperty(queue, kAudioQueueProperty_MaximumOutputPacketSize, &maxPacket, &s);
    }
    Float64 bytes = desc.mSampleRate * maxPacket * 0.5;
    if (bytes < kMinimumBufferSize) *outSize = kMinimumBufferSize;
    else if (bytes > kMaximumBufferSize) *outSize = kMaximumBufferSize;
    else *outSize = (UInt32)bytes;
}

#pragma mark 开始录音

- (BOOL)startWithChannel:(TRChannel)channel fileURL:(NSURL *)fileURL error:(NSError **)error {
    if (_recording) return YES;

    CRLog(@"===== 开始录音 =====");
    CRLog(@"iOS=%@ 机型=%@ 通道=%ld 档位采样率=%ld",
          [UIDevice currentDevice].systemVersion, [UIDevice currentDevice].model,
          (long)channel, (long)self.outputSampleRate);

    // ★ 关键修复：官方 CLI 从不激活 AVAudioSession（靠 CanRecordWithoutSessionActivation 权限）。
    //   之前这里 setCategory:PlayAndRecord + setActive 会抢走私有 tap 的音频路由，导致录不到。

    switch (channel) {
        case TRChannelSystemAudio: _tapPID = kATAudioTapDescriptionPIDSystemAudio; break;
        case TRChannelMicrophone:  _tapPID = kATAudioTapDescriptionPIDMicrophone;  break;
        case TRChannelSpeaker:     _tapPID = kATAudioTapDescriptionPIDSpeaker;     break;
    }
    UInt32 tapChannels = (channel == TRChannelMicrophone) ? 1 : 2;   // 官方：内置麦克风单声道，其余双声道
    CRLog(@"tap PID=%d 采集通道=%u 采集采样率=%.0f", _tapPID, (unsigned)tapChannels, kTapSampleRate);

    AVAudioFormat *audioFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                                  sampleRate:kTapSampleRate
                                                                    channels:tapChannels
                                                                 interleaved:YES];
    if (!audioFormat) return [self fail:-1 error:error where:@"创建 AVAudioFormat"];
    _tapFormat = *([audioFormat streamDescription]);

    ATAudioTapDescription *tapDesc = nil;
    if ([ATAudioTapDescription instancesRespondToSelector:@selector(initTapInternalWithFormat:PIDs:)]) {
        tapDesc = [[ATAudioTapDescription alloc] initTapInternalWithFormat:audioFormat PIDs:@[@(_tapPID)]];
        CRLog(@"tap 初始化：initTapInternalWithFormat:PIDs: (iOS16+)");
    } else {
        tapDesc = [[ATAudioTapDescription alloc] initProcessTapInternalWithFormat:audioFormat PID:_tapPID];
        CRLog(@"tap 初始化：initProcessTapInternalWithFormat:PID:");
    }
    _audioTap = [[ATAudioTap alloc] initWithTapDescription:tapDesc];
    if (!_audioTap) return [self fail:-2 error:error where:@"创建 ATAudioTap"];

    OSStatus status = AudioQueueNewInput(&_tapFormat, RecorderCallback, (__bridge void *)self,
                                         NULL, NULL, 0x800, &_queue);
    CRLog(@"AudioQueueNewInput=%d", (int)status);
    if (status != noErr) return [self fail:status error:error where:@"AudioQueueNewInput"];

    status = AudioQueueSetProperty(_queue, kAudioQueueProperty_TapOutputBypass,
                                   (__bridge void *)_audioTap, 8);
    CRLog(@"TapOutputBypass(qtob)=%d", (int)status);
    if (status != noErr) return [self fail:status error:error where:@"TapOutputBypass"];

    CalculateBufferSize(_queue, _tapFormat, &_bufferSize);
    for (int i = 0; i < kNumberOfBuffers; i++) {
        OSStatus s = AudioQueueAllocateBuffer(_queue, _bufferSize, &_buffers[i]);
        if (s != noErr) return [self fail:s error:error where:@"AudioQueueAllocateBuffer"];
        AudioQueueEnqueueBuffer(_queue, _buffers[i], 0, NULL);
    }
    CRLog(@"缓冲区=%u 字节 x %d", (unsigned)_bufferSize, kNumberOfBuffers);

    // 输出：按档位采样率 / 单声道 / AAC。ExtAudioFile 自动把 44100/stereo PCM 重采样为档位 mono。
    AudioStreamBasicDescription outFormat = {0};
    UInt32 outSize = sizeof(outFormat);
    outFormat.mFormatID = kAudioFormatMPEG4AAC;
    outFormat.mSampleRate = SampleRateForQuality(_quality);
    outFormat.mChannelsPerFrame = 1;
    status = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL, &outSize, &outFormat);
    CRLog(@"AAC FormatInfo=%d 输出采样率=%.0f", (int)status, outFormat.mSampleRate);
    if (status != noErr) return [self fail:status error:error where:@"AAC FormatInfo"];

    AudioChannelLayout layout = {0};
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;

    status = ExtAudioFileCreateWithURL((__bridge CFURLRef)fileURL, kAudioFileM4AType, &outFormat,
                                       &layout, kAudioFileFlags_EraseFile, &_extFile);
    CRLog(@"ExtAudioFileCreateWithURL=%d", (int)status);
    if (status != noErr) return [self fail:status error:error where:@"ExtAudioFileCreate"];

    status = ExtAudioFileSetProperty(_extFile, kExtAudioFileProperty_ClientDataFormat,
                                     sizeof(_tapFormat), &_tapFormat);
    CRLog(@"ClientDataFormat=%d", (int)status);
    if (status != noErr) return [self fail:status error:error where:@"ClientDataFormat"];

    AudioConverterRef converter = NULL;
    UInt32 converterSize = sizeof(converter);
    if (ExtAudioFileGetProperty(_extFile, kExtAudioFileProperty_AudioConverter, &converterSize, &converter) == noErr
        && converter) {
        UInt32 bitRate = BitRateForQuality(_quality);
        AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, sizeof(bitRate), &bitRate);
        CRLog(@"AAC 码率=%u", (unsigned)bitRate);
    }

    AudioQueueAddPropertyListener(_queue, kAudioQueueProperty_IsRunning, ListenerCallback, (__bridge void *)self);

    status = AudioQueueStart(_queue, NULL);
    CRLog(@"AudioQueueStart=%d", (int)status);
    if (status != noErr) return [self fail:status error:error where:@"AudioQueueStart"];

    _waitingDevice = YES;
    _recording = YES;
    _totalBytes = 0;
    _callbackCount = 0;
    return YES;
}

- (BOOL)fail:(OSStatus)status error:(NSError **)error where:(NSString *)where {
    CRLog(@"★ 失败：%@ code=%d", where, (int)status);
    if (error) {
        *error = [NSError errorWithDomain:@"RecorderEngine" code:status
                                userInfo:@{NSLocalizedDescriptionKey:
                                    [NSString stringWithFormat:@"%@ 失败 (code %d)", where, (int)status]}];
    }
    [self cleanup];
    return NO;
}

#pragma mark 停止录音

- (void)stop {
    if (!_recording && !_waitingDevice) { [self cleanup]; return; }
    CRLog(@"停止录音：回调次数=%d 写入PCM字节=%llu", _callbackCount, _totalBytes);
    AudioQueueStop(_queue, false);   // 非立即停止，让在途缓冲写完
    _recording = NO;
    _waitingDevice = NO;
    // 直接同步收尾：确保 AAC 编码器 flush、文件头写完整（之前 0.3s 异步容易写出打不开的空壳）
    [self cleanup];
}

- (void)cleanup {
    if (_queue) { AudioQueueRemovePropertyListener(_queue, kAudioQueueProperty_IsRunning, ListenerCallback, (__bridge void *)self); }
    if (_extFile) { ExtAudioFileDispose(_extFile); CRLog(@"文件已封装关闭"); _extFile = NULL; }
    if (_queue) { AudioQueueDispose(_queue, true); _queue = NULL; }
    _audioTap = nil;
    _recording = NO;
    _waitingDevice = NO;
    CRLog(@"===== 结束 =====\n");
}

- (void)dealloc { [self cleanup]; }

@end
