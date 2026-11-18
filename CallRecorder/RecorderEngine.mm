#import "RecorderEngine.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <math.h>

#import "ATAudioTap.h"
#import "ATAudioTapDescription.h"
#import "AudioQueue+Private.h"

#pragma mark - 说明
// v3.0：完全照搬官方 TrollRecorder 的 recorder.mm（真正用于通话录音的工具）。
// 之前 v1/v2 抄错了 call-recorder.mm —— 那是实验性的"系统音频旁路(qtob)"分支，
// 且我误删了 AVAudioSession 激活（recorder.mm 恰恰必须激活）。v3 全部改回官方配方。

static const int kNumberOfBuffers   = 3;
static const int kMaximumBufferSize = 0x50000;
static const int kMinimumBufferSize = 0x4000;
static const Float64 kTapSampleRate = 44100.0;   // 官方 recorder.mm 固定 44100

#pragma mark - 诊断日志

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
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [[line dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url atomically:YES]; }
    NSLog(@"[Recorder] %@", body);
}

#pragma mark - 引擎

@interface RecorderEngine () {
    AudioStreamBasicDescription _dataFormat;
    AudioQueueRef               _queue;
    AudioQueueBufferRef         _buffers[kNumberOfBuffers];
    AudioFileID                 _audioFile;
    UInt32                      _bufferSize;
    SInt64                      _currentPacket;
    int                         _tapPID;
    ATAudioTap                 *_audioTap;
    BOOL                        _recording;
    UInt64                      _totalBytes;
    int                         _callbackCount;
    float                       _peakLevel;
    double                      _sumSquares;
    UInt64                      _sampleCount;
}
@end

@implementation RecorderEngine

+ (NSString *)qualityDescription:(TRQuality)q {
    // v3 采集固定 44100 PCM（官方配方），档位仅作展示占位，保证先录到声音
    return @"官方原版 44.1kHz CAF（约 10 MB/分钟）";
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

- (NSInteger)outputSampleRate { return (NSInteger)kTapSampleRate; }
- (NSURL *)debugLogURL { return CRDebugLogURL(); }
- (BOOL)isRecording { return _recording; }
- (float)peakLevel { return _peakLevel; }

#pragma mark 采集回调：官方写法 AudioFileWritePackets 直接写 PCM（不编码，最稳）

static void RecorderCallback(void *ptr, AudioQueueRef aq, AudioQueueBufferRef buffer,
                             const AudioTimeStamp *ts, UInt32 numPackets,
                             const AudioStreamPacketDescription *packetDesc) {
    RecorderEngine *self = (__bridge RecorderEngine *)ptr;

    if (numPackets == 0 && self->_dataFormat.mBytesPerPacket != 0) {
        numPackets = buffer->mAudioDataByteSize / self->_dataFormat.mBytesPerPacket;
    }
    OSStatus st = AudioFileWritePackets(self->_audioFile, false, buffer->mAudioDataByteSize,
                                         packetDesc, self->_currentPacket, &numPackets, buffer->mAudioData);
    if (st == noErr) {
        self->_currentPacket += numPackets;
    }

    // 电平检测：Float32 PCM
    Float32 *samples = (Float32 *)buffer->mAudioData;
    UInt32 count = buffer->mAudioDataByteSize / sizeof(Float32);
    for (UInt32 i = 0; i < count; i++) {
        Float32 v = samples[i];
        Float32 a = fabsf(v);
        if (a > self->_peakLevel) self->_peakLevel = a;
        self->_sumSquares += (double)v * v;
        self->_sampleCount++;
    }
    self->_totalBytes += buffer->mAudioDataByteSize;
    self->_callbackCount++;
    if (st != noErr && self->_callbackCount <= 3) {
        CRLog(@"写盘失败 AudioFileWritePackets=%d", (int)st);
    }

    if (self->_recording) AudioQueueEnqueueBuffer(aq, buffer, 0, NULL);
}

static void ListenerCallback(void *userData, AudioQueueRef queue, AudioQueuePropertyID prop) {
    RecorderEngine *self = (__bridge RecorderEngine *)userData;
    UInt32 running = 0, size = sizeof(running);
    if (AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &running, &size) == noErr) {
        CRLog(@"AudioQueue IsRunning=%u", (unsigned)running);
        if (running == 0) self->_recording = NO;
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

#pragma mark 开始

- (BOOL)startWithChannel:(TRChannel)channel fileURL:(NSURL *)fileURL error:(NSError **)error {
    if (_recording) return YES;
    CRLog(@"===== 开始录音 v3 ===== iOS=%@", [UIDevice currentDevice].systemVersion);

    // 官方 recorder.mm：只支持 mic / speaker。sys(PID=-1) 是收费的系统音频，不在此实现。
    switch (channel) {
        case TRChannelMicrophone:  _tapPID = kATAudioTapDescriptionPIDMicrophone;  break;
        case TRChannelSpeaker:     _tapPID = kATAudioTapDescriptionPIDSpeaker;     break;
        case TRChannelSystemAudio:
        default:                   _tapPID = kATAudioTapDescriptionPIDMicrophone;  break;  // 强制回退麦克风
    }
    UInt32 channels = (_tapPID == kATAudioTapDescriptionPIDMicrophone) ? 1 : 2;
    CRLog(@"通道 PID=%d 采集声道=%u 采样率=%.0f", _tapPID, (unsigned)channels, kTapSampleRate);

    // ★ 官方 recorder.mm 的 AVAudioSession 配方（之前误删，这是录到声音的必要条件）
    NSError *sessErr = nil;
    BOOL ok = [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord
                                                     mode:AVAudioSessionModeDefault
                                                  options:AVAudioSessionCategoryOptionMixWithOthers
                                                    error:&sessErr];
    CRLog(@"setCategory=%d err=%@", ok, sessErr.localizedDescription);
    ok = [[AVAudioSession sharedInstance] setActive:YES error:&sessErr];
    CRLog(@"setActive=%d err=%@", ok, sessErr.localizedDescription);

    // 采集格式 Float32 PCM —— 与官方 recorder.mm 第 121-131 行一致
    AVAudioFormat *audioFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                                  sampleRate:kTapSampleRate
                                                                    channels:channels
                                                                 interleaved:YES];
    if (!audioFormat) return [self fail:-1 error:error where:@"AVAudioFormat"];
    _dataFormat = *([audioFormat streamDescription]);

    ATAudioTapDescription *tapDesc = nil;
    if ([ATAudioTapDescription instancesRespondToSelector:@selector(initTapInternalWithFormat:PIDs:)]) {
        tapDesc = [[ATAudioTapDescription alloc] initTapInternalWithFormat:audioFormat PIDs:@[@(_tapPID)]];
        CRLog(@"tap: initTapInternalWithFormat (iOS16+)");
    } else {
        tapDesc = [[ATAudioTapDescription alloc] initProcessTapInternalWithFormat:audioFormat PID:_tapPID];
        CRLog(@"tap: initProcessTapInternal");
    }
    _audioTap = [[ATAudioTap alloc] initWithTapDescription:tapDesc];
    if (!_audioTap) return [self fail:-2 error:error where:@"ATAudioTap"];

    // ★ 官方 recorder.mm：flag = 0（不是实验分支的 0x800），且没有 TapOutputBypass
    OSStatus status = AudioQueueNewInput(&_dataFormat, RecorderCallback, (__bridge void *)self,
                                         NULL, NULL, 0, &_queue);
    CRLog(@"AudioQueueNewInput(flag=0)=%d", (int)status);
    if (status != noErr) return [self fail:status error:error where:@"AudioQueueNewInput"];

    CalculateBufferSize(_queue, _dataFormat, &_bufferSize);
    for (int i = 0; i < kNumberOfBuffers; i++) {
        OSStatus s = AudioQueueAllocateBuffer(_queue, _bufferSize, &_buffers[i]);
        if (s != noErr) return [self fail:s error:error where:@"AudioQueueAllocateBuffer"];
        AudioQueueEnqueueBuffer(_queue, _buffers[i], 0, NULL);
    }
    CRLog(@"缓冲区=%u x %d", (unsigned)_bufferSize, kNumberOfBuffers);

    // 官方写盘：CAF + Float32 PCM + MagicCookie
    _currentPacket = 0;
    status = AudioFileCreateWithURL((__bridge CFURLRef)fileURL, kAudioFileCAFType, &_dataFormat,
                                    kAudioFileFlags_EraseFile, &_audioFile);
    CRLog(@"AudioFileCreateWithURL(CAF)=%d", (int)status);
    if (status != noErr) return [self fail:status error:error where:@"AudioFileCreate"];

    UInt32 cookieSize = sizeof(UInt32);
    if (AudioQueueGetPropertySize(_queue, kAudioQueueProperty_MagicCookie, &cookieSize) == noErr) {
        void *cookie = malloc(cookieSize);
        if (AudioQueueGetProperty(_queue, kAudioQueueProperty_MagicCookie, cookie, &cookieSize) == noErr) {
            AudioFileSetProperty(_audioFile, kAudioFilePropertyMagicCookieData, cookieSize, cookie);
        }
        free(cookie);
    }

    AudioQueueAddPropertyListener(_queue, kAudioQueueProperty_IsRunning, ListenerCallback, (__bridge void *)self);

    status = AudioQueueStart(_queue, NULL);
    CRLog(@"AudioQueueStart=%d", (int)status);
    if (status != noErr) return [self fail:status error:error where:@"AudioQueueStart"];

    _recording = YES;
    _totalBytes = 0; _callbackCount = 0; _peakLevel = 0; _sumSquares = 0; _sampleCount = 0;
    return YES;
}

- (BOOL)fail:(OSStatus)status error:(NSError **)error where:(NSString *)where {
    CRLog(@"★失败 %@ code=%d", where, (int)status);
    if (error) *error = [NSError errorWithDomain:@"RecorderEngine" code:status
                                       userInfo:@{NSLocalizedDescriptionKey:
                                           [NSString stringWithFormat:@"%@ 失败 (code %d)", where, (int)status]}];
    [self cleanup];
    return NO;
}

- (void)stop {
    if (!_recording) { [self cleanup]; return; }
    double rms = _sampleCount > 0 ? sqrt(_sumSquares / (double)_sampleCount) : 0.0;
    CRLog(@"停止：回调=%d 字节=%llu 峰值=%.4f RMS=%.5f", _callbackCount, _totalBytes, _peakLevel, rms);
    if (_peakLevel < 0.001f) CRLog(@"⚠️静音：tap无有效声音");
    else CRLog(@"✅有声音 峰值=%.4f", _peakLevel);
    AudioQueueStop(_queue, true);
    _recording = NO;
    [self cleanup];
}

- (void)cleanup {
    if (_queue) AudioQueueRemovePropertyListener(_queue, kAudioQueueProperty_IsRunning, ListenerCallback, (__bridge void *)self);
    if (_audioFile) { AudioFileClose(_audioFile); _audioFile = 0; CRLog(@"文件已关闭"); }
    if (_queue) { AudioQueueDispose(_queue, true); _queue = NULL; }
    _audioTap = nil;
    _recording = NO;
    [[AVAudioSession sharedInstance] setActive:NO
                                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                         error:nil];
    CRLog(@"===== 结束 =====\n");
}

- (void)dealloc { [self cleanup]; }

@end
