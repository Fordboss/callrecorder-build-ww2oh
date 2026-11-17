#import "RecorderEngine.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

#import "ATAudioTap.h"
#import "ATAudioTapDescription.h"
#import "AudioQueue+Private.h"

#pragma mark - 体积档位（改这 3 个数字即可调音质/体积）
static const Float64 kSampleRate = 16000.0;  // 16kHz 人声够用；44100 更保真但体积翻倍
static const UInt32  kChannels   = 1;        // 单声道；2 = 立体声
static const UInt32  kAACBitRate = 32000;    // 32kbps 够用；64000 音质更好

static const int kNumberOfBuffers  = 3;
static const int kMaximumBufferSize = 0x50000;
static const int kMinimumBufferSize = 0x4000;

@interface RecorderEngine () {
    AudioStreamBasicDescription _dataFormat;
    AudioQueueRef               _queue;
    AudioQueueBufferRef         _buffers[kNumberOfBuffers];
    ExtAudioFileRef             _extFile;
    UInt32                      _bufferSize;
    int                         _tapPID;
    ATAudioTap                 *_audioTap;
    BOOL                        _recording;
    BOOL                        _waitingDevice;
    NSTimeInterval              _startedAt;
}
@end

@implementation RecorderEngine

+ (instancetype)shared {
    static RecorderEngine *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (BOOL)isRecording { return _recording; }

#pragma mark - 采集回调：PCM -> ExtAudioFile 编码成 AAC
static void RecorderCallback(void *ptr, AudioQueueRef aq, AudioQueueBufferRef buffer,
                             const AudioTimeStamp *ts, UInt32 numPackets,
                             const AudioStreamPacketDescription *packetDesc) {
    RecorderEngine *self = (__bridge RecorderEngine *)ptr;
    if (self->_extFile && buffer->mAudioDataByteSize > 0) {
        AudioBufferList list;
        list.mNumberBuffers = 1;
        list.mBuffers[0].mNumberChannels = self->_dataFormat.mChannelsPerFrame;
        list.mBuffers[0].mDataByteSize = buffer->mAudioDataByteSize;
        list.mBuffers[0].mData = buffer->mAudioData;
        UInt32 frames = buffer->mAudioDataByteSize / self->_dataFormat.mBytesPerFrame;
        ExtAudioFileWrite(self->_extFile, frames, &list);
    }
    if (self->_recording) {
        AudioQueueEnqueueBuffer(aq, buffer, 0, NULL);
    }
}

static void ListenerCallback(void *userData, AudioQueueRef queue, AudioQueuePropertyID prop) {
    RecorderEngine *self = (__bridge RecorderEngine *)userData;
    UInt32 running = 0, size = sizeof(running);
    if (AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &running, &size) == noErr) {
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

#pragma mark - 开始录音
- (BOOL)startWithChannel:(TRChannel)channel fileURL:(NSURL *)fileURL error:(NSError **)error {
    if (_recording) return YES;

    // 麦克风权限（系统/扬声器 tap 不需要，但统一申请，失败不阻断）
    [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
        if (!granted) NSLog(@"麦克风权限未授予（系统音频 tap 不受影响）");
    }];

    switch (channel) {
        case TRChannelSystemAudio: _tapPID = kATAudioTapDescriptionPIDSystemAudio; break;
        case TRChannelMicrophone:  _tapPID = kATAudioTapDescriptionPIDMicrophone;  break;
        case TRChannelSpeaker:     _tapPID = kATAudioTapDescriptionPIDSpeaker;     break;
    }

    // tap 用 Float32 PCM（CoreAudio tap 原生格式），采样率声道按档位
    AVAudioFormat *audioFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                                  sampleRate:(double)kSampleRate
                                                                    channels:(AVAudioChannelCount)kChannels
                                                                 interleaved:YES];
    if (!audioFormat) {
        if (error) *error = [NSError errorWithDomain:@"RecorderEngine" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"音频格式创建失败"}];
        return NO;
    }
    _dataFormat = *([audioFormat streamDescription]);

    ATAudioTapDescription *tapDesc = nil;
    if ([ATAudioTapDescription instancesRespondToSelector:@selector(initTapInternalWithFormat:PIDs:)]) {
        tapDesc = [[ATAudioTapDescription alloc] initTapInternalWithFormat:audioFormat PIDs:@[@(_tapPID)]];
    } else {
        tapDesc = [[ATAudioTapDescription alloc] initProcessTapInternalWithFormat:audioFormat PID:_tapPID];
    }
    _audioTap = [[ATAudioTap alloc] initWithTapDescription:tapDesc];

    OSStatus status = AudioQueueNewInput(&_dataFormat, RecorderCallback, (__bridge void *)self,
                                         NULL, NULL, 0x800, &_queue);
    if (status != noErr) return [self fail:status error:error where:@"AudioQueueNewInput"];

    status = AudioQueueSetProperty(_queue, kAudioQueueProperty_TapOutputBypass,
                                   (__bridge void *)_audioTap, 8);
    if (status != noErr) return [self fail:status error:error where:@"TapOutputBypass"];

    CalculateBufferSize(_queue, _dataFormat, &_bufferSize);
    for (int i = 0; i < kNumberOfBuffers; i++) {
        AudioQueueAllocateBuffer(_queue, _bufferSize, &_buffers[i]);
        AudioQueueEnqueueBuffer(_queue, _buffers[i], 0, NULL);
    }

    // 输出 AAC / m4a
    AudioStreamBasicDescription outFormat = {0};
    UInt32 outSize = sizeof(outFormat);
    outFormat.mFormatID = kAudioFormatMPEG4AAC;
    outFormat.mSampleRate = kSampleRate;
    outFormat.mChannelsPerFrame = kChannels;
    status = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL, &outSize, &outFormat);
    if (status != noErr) return [self fail:status error:error where:@"AAC FormatInfo"];

    AudioChannelLayout layout = {0};
    layout.mChannelLayoutTag = (kChannels == 1) ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo;

    status = ExtAudioFileCreateWithURL((__bridge CFURLRef)fileURL, kAudioFileM4AType, &outFormat,
                                       &layout, kAudioFileFlags_EraseFile, &_extFile);
    if (status != noErr) return [self fail:status error:error where:@"ExtAudioFileCreate"];

    status = ExtAudioFileSetProperty(_extFile, kExtAudioFileProperty_ClientDataFormat,
                                     sizeof(_dataFormat), &_dataFormat);
    if (status != noErr) return [self fail:status error:error where:@"ClientDataFormat"];

    AudioConverterRef converter = NULL;
    UInt32 converterSize = sizeof(converter);
    if (ExtAudioFileGetProperty(_extFile, kExtAudioFileProperty_AudioConverter, &converterSize, &converter) == noErr
        && converter) {
        UInt32 bitRate = kAACBitRate;
        AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, sizeof(bitRate), &bitRate);
    }

    AudioQueueAddPropertyListener(_queue, kAudioQueueProperty_IsRunning, ListenerCallback, (__bridge void *)self);

    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];

    status = AudioQueueStart(_queue, NULL);
    if (status != noErr) return [self fail:status error:error where:@"AudioQueueStart"];

    _waitingDevice = YES;
    _recording = YES;
    _startedAt = [[NSDate date] timeIntervalSinceReferenceDate];
    return YES;
}

- (BOOL)fail:(OSStatus)status error:(NSError **)error where:(NSString *)where {
    NSLog(@"%@ failed: %d", where, (int)status);
    if (error) {
        *error = [NSError errorWithDomain:@"RecorderEngine" code:status
                                userInfo:@{NSLocalizedDescriptionKey:
                                    [NSString stringWithFormat:@"%@ 失败 (code %d)", where, (int)status]}];
    }
    [self cleanup];
    return NO;
}

#pragma mark - 停止录音
- (void)stop {
    if (!_recording && !_waitingDevice) {
        [self cleanup];
        return;
    }
    AudioQueueStop(_queue, true);
    _recording = NO;
    _waitingDevice = NO;
    // 给回调一点时间写完最后的缓冲，再关闭文件（flush AAC 头）
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf cleanup];
    });
}

- (void)cleanup {
    if (_extFile) { ExtAudioFileDispose(_extFile); _extFile = NULL; }
    if (_queue) { AudioQueueDispose(_queue, true); _queue = NULL; }
    _audioTap = nil;
    _recording = NO;
    _waitingDevice = NO;
    [[AVAudioSession sharedInstance] setActive:NO
                                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                         error:nil];
}

- (void)dealloc { [self cleanup]; }

@end
