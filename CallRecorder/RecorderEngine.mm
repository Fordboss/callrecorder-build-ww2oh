#import "RecorderEngine.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <math.h>

#import "ATAudioTap.h"
#import "ATAudioTapDescription.h"
#import "AudioQueue+Private.h"

// v5.0：对标官方 TrollRecorder 的完整配方。
//  - 双路 tap 同时采集：麦克风(自己, PID=-3) + 扬声器/听筒(对方, PID=-2)
//  - 两路各写 Float32 CAF（flag=0x800 + qtob 接 tap；不激活 AVAudioSession）
//  - 停止后由 Mixer 用 ExtAudioFile 把两路重采样 + 合成为 AAC/m4a（采样率可选，小体积）
//  - 这是官方 mixer.mm + call-recorder.mm 的组合，也是"能录通话双方+可调采样率+体积正常"的正解。

static const int    kNumberOfBuffers   = 3;
static const UInt32 kMaximumBufferSize = 0x50000;
static const UInt32 kMinimumBufferSize = 0x4000;
static const Float64 kTapSampleRate    = 44100.0;   // tap 采集固定 44.1k，输出重采样

// 采样率档位（输出 m4a）
static Float64 SampleRateForQuality(TRQuality q) {
    switch (q) {
        case TRQualityHigh:   return 44100.0;
        case TRQualityNormal: return 22050.0;
        case TRQualitySmall:
        default:              return 16000.0;
    }
}
// AAC 目标码率
static UInt32 BitrateForQuality(TRQuality q) {
    switch (q) {
        case TRQualityHigh:   return 96000;
        case TRQualityNormal: return 64000;
        case TRQualitySmall:
        default:              return 32000;
    }
}

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

#pragma mark - 单路采集通道

@interface CaptureChannel : NSObject {
@public
    AudioStreamBasicDescription format;
    AudioQueueRef               queue;
    AudioQueueBufferRef         buffers[kNumberOfBuffers];
    AudioFileID                 audioFile;
    UInt32                      bufferSize;
    SInt64                      currentPacket;
    int                         pid;
    ATAudioTap                 *tap;
    float                       peak;
    double                      sumSq;
    UInt64                      sampleCount;
    int                         callbacks;
    UInt64                      totalBytes;
    BOOL                        running;
}
@end
@implementation CaptureChannel
@end

#pragma mark - 混音器（对标官方 mixer.mm）

// 把两路 Float32 CAF 重采样 + 合成为单文件 AAC/m4a。
// input2 为 nil 时：单路，左右声道都写 input1。
static BOOL MixCAFs(NSURL *in1, NSURL *in2, NSURL *outURL, Float64 outSR, UInt32 bitrate, NSString **errMsg) {
    ExtAudioFileRef f1 = NULL, f2 = NULL, fout = NULL;
    AudioStreamBasicDescription clientFmt = {0}, outFmt = {0};
    OSStatus st = noErr;
    BOOL ok = NO;
    const UInt32 framesPerBuf = 8192;
#define CRMAX(a,b) ((a)>(b)?(a):(b))

    st = ExtAudioFileOpenURL((__bridge CFURLRef)in1, &f1);
    if (st != noErr) { if (errMsg) *errMsg = [NSString stringWithFormat:@"打开输入1失败 %d", (int)st]; goto done; }
    if (in2) {
        st = ExtAudioFileOpenURL((__bridge CFURLRef)in2, &f2);
        if (st != noErr) { if (errMsg) *errMsg = [NSString stringWithFormat:@"打开输入2失败 %d", (int)st]; goto done; }
    }

    // 读取端：统一转成 Int16 / 目标采样率 / 单声道（每路各自读）
    clientFmt.mSampleRate       = outSR;
    clientFmt.mFormatID         = kAudioFormatLinearPCM;
    clientFmt.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    clientFmt.mFramesPerPacket  = 1;
    clientFmt.mChannelsPerFrame = 1;
    clientFmt.mBitsPerChannel   = 16;
    clientFmt.mBytesPerFrame    = 2;
    clientFmt.mBytesPerPacket   = 2;

    ExtAudioFileSetProperty(f1, kExtAudioFileProperty_ClientDataFormat, sizeof(clientFmt), &clientFmt);
    if (f2) ExtAudioFileSetProperty(f2, kExtAudioFileProperty_ClientDataFormat, sizeof(clientFmt), &clientFmt);

    // 输出：AAC / 立体声 / 目标采样率
    outFmt.mSampleRate       = outSR;
    outFmt.mFormatID         = kAudioFormatMPEG4AAC;
    outFmt.mChannelsPerFrame = 2;
    UInt32 sz = sizeof(outFmt);
    st = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL, &sz, &outFmt);
    if (st != noErr) { if (errMsg) *errMsg = [NSString stringWithFormat:@"FormatInfo失败 %d", (int)st]; goto done; }

    AudioChannelLayout layout = {0};
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
    st = ExtAudioFileCreateWithURL((__bridge CFURLRef)outURL, kAudioFileM4AType, &outFmt, &layout,
                                   kAudioFileFlags_EraseFile, &fout);
    if (st != noErr) { if (errMsg) *errMsg = [NSString stringWithFormat:@"创建m4a失败 %d", (int)st]; goto done; }

    // 写入端用 Int16 立体声，由 ExtAudioFile 编码为 AAC
    AudioStreamBasicDescription writeFmt = clientFmt;
    writeFmt.mChannelsPerFrame = 2;
    writeFmt.mBytesPerFrame    = 4;
    writeFmt.mBytesPerPacket   = 4;
    ExtAudioFileSetProperty(fout, kExtAudioFileProperty_ClientDataFormat, sizeof(writeFmt), &writeFmt);
    UInt32 quality = 0; // 0=最大压缩率优先(体积); 用码率控制
    ExtAudioFileSetProperty(fout, kExtAudioFileProperty_EncoderQuality, sizeof(quality), &quality);
    ExtAudioFileSetProperty(fout, kExtAudioFileProperty_EncoderBitRate, sizeof(bitrate), &bitrate);

    // 缓冲区（每路单声道 Int16，输出立体声 Int16）
    SInt16 *b1 = (SInt16 *)calloc(framesPerBuf, sizeof(SInt16));
    SInt16 *b2 = (SInt16 *)calloc(framesPerBuf, sizeof(SInt16));
    SInt16 *bo = (SInt16 *)calloc(framesPerBuf * 2, sizeof(SInt16));
    if (!b1 || !b2 || !bo) { free(b1); free(b2); free(bo); if (errMsg) *errMsg = @"内存分配失败"; goto done; }

    AudioBufferList abl1 = {0}; abl1.mNumberBuffers = 1;
    abl1.mBuffers[0].mNumberChannels = 1;
    abl1.mBuffers[0].mDataByteSize = framesPerBuf * sizeof(SInt16);
    abl1.mBuffers[0].mData = b1;
    AudioBufferList abl2 = {0}; abl2.mNumberBuffers = 1;
    abl2.mBuffers[0].mNumberChannels = 1;
    abl2.mBuffers[0].mDataByteSize = framesPerBuf * sizeof(SInt16);
    abl2.mBuffers[0].mData = b2;
    AudioBufferList ablo = {0}; ablo.mNumberBuffers = 1;
    ablo.mBuffers[0].mNumberChannels = 2;
    ablo.mBuffers[0].mDataByteSize = framesPerBuf * 2 * sizeof(SInt16);
    ablo.mBuffers[0].mData = bo;

    while (1) {
        UInt32 n1 = framesPerBuf, n2 = framesPerBuf;
        st = ExtAudioFileRead(f1, &n1, &abl1);
        if (st != noErr) { CRLog(@"混音读输入1失败 %d", (int)st); break; }
        if (f2) {
            st = ExtAudioFileRead(f2, &n2, &abl2);
            if (st != noErr) { CRLog(@"混音读输入2失败 %d", (int)st); break; }
        } else {
            n2 = n1; // 单路：右声道复制左声道
        }
        if (n1 == 0 && n2 == 0) break;

        UInt32 frames = CRMAX(n1, n2);
        for (UInt32 i = 0; i < frames; i++) {
            SInt16 l = (i < n1) ? b1[i] : 0;
            SInt16 r;
            if (f2) r = (i < n2) ? b2[i] : 0;
            else    r = l;                 // 单路复制到双声道
            bo[i*2]   = l;                 // 左：麦克风（自己）
            bo[i*2+1] = r;                 // 右：扬声器（对方）
        }
        ablo.mBuffers[0].mDataByteSize = frames * 2 * sizeof(SInt16);
        UInt32 framesToWrite = frames;
        st = ExtAudioFileWrite(fout, framesToWrite, &ablo);
        if (st != noErr) { CRLog(@"混音写输出失败 %d", (int)st); break; }
    }
    free(b1); free(b2); free(bo);
    ok = YES;

done:
    if (f1) ExtAudioFileDispose(f1);
    if (f2) ExtAudioFileDispose(f2);
    if (fout) ExtAudioFileDispose(fout);
    return ok;
}

#pragma mark - 引擎

@interface RecorderEngine () {
    CaptureChannel *_mic;
    CaptureChannel *_spk;
    NSURL *_outURL;
    NSURL *_micURL;
    NSURL *_spkURL;
    TRChannel _channel;
    BOOL _recording;
}
@end

@implementation RecorderEngine

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

+ (NSString *)qualityDescription:(TRQuality)q {
    switch (q) {
        case TRQualityHigh:   return @"高清 44.1kHz · 约 0.6 MB/分";
        case TRQualityNormal: return @"标准 22.05kHz · 约 0.35 MB/分";
        case TRQualitySmall:
        default:              return @"省空间 16kHz · 约 0.25 MB/分";
    }
}

- (NSInteger)outputSampleRate { return (NSInteger)SampleRateForQuality(_quality); }
- (NSURL *)debugLogURL { return CRDebugLogURL(); }
- (BOOL)isRecording { return _recording; }
- (float)peakLevel { return MAX(_mic ? _mic->peak : 0, _spk ? _spk->peak : 0); }
- (float)micLevel { return _mic ? _mic->peak : 0; }
- (float)speakerLevel { return _spk ? _spk->peak : 0; }

#pragma mark 采集回调

static void RecorderCallback(void *ptr, AudioQueueRef aq, AudioQueueBufferRef buffer,
                             const AudioTimeStamp *ts, UInt32 numPackets,
                             const AudioStreamPacketDescription *packetDesc) {
    CaptureChannel *ch = (__bridge CaptureChannel *)ptr;
    if (numPackets == 0 && ch->format.mBytesPerPacket != 0)
        numPackets = buffer->mAudioDataByteSize / ch->format.mBytesPerPacket;

    OSStatus st = AudioFileWritePackets(ch->audioFile, false, buffer->mAudioDataByteSize,
                                        packetDesc, ch->currentPacket, &numPackets, buffer->mAudioData);
    if (st == noErr) ch->currentPacket += numPackets;
    else if (ch->callbacks <= 3) CRLog(@"写盘失败 pid=%d st=%d", ch->pid, (int)st);

    Float32 *s = (Float32 *)buffer->mAudioData;
    UInt32 count = buffer->mAudioDataByteSize / sizeof(Float32);
    for (UInt32 i = 0; i < count; i++) {
        Float32 a = fabsf(s[i]);
        if (a > ch->peak) ch->peak = a;
        ch->sumSq += (double)s[i] * s[i];
        ch->sampleCount++;
    }
    ch->totalBytes += buffer->mAudioDataByteSize;
    ch->callbacks++;
    if (ch->running) AudioQueueEnqueueBuffer(aq, buffer, 0, NULL);
}

static void ListenerCallback(void *userData, AudioQueueRef queue, AudioQueuePropertyID prop) {
    CaptureChannel *ch = (__bridge CaptureChannel *)userData;
    UInt32 running = 0, size = sizeof(running);
    if (AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &running, &size) == noErr)
        CRLog(@"queue pid=%d IsRunning=%u", ch->pid, (unsigned)running);
}

static void CalcBufSize(AudioQueueRef q, AudioStreamBasicDescription desc, UInt32 *out) {
    UInt32 maxPacket = desc.mBytesPerPacket;
    if (!maxPacket) { UInt32 s = sizeof(maxPacket); AudioQueueGetProperty(q, kAudioQueueProperty_MaximumOutputPacketSize, &maxPacket, &s); }
    Float64 bytes = desc.mSampleRate * maxPacket * 0.5;
    if (bytes < kMinimumBufferSize) *out = kMinimumBufferSize;
    else if (bytes > kMaximumBufferSize) *out = kMaximumBufferSize;
    else *out = (UInt32)bytes;
}

#pragma mark 启动单路

- (CaptureChannel *)startChannelWithPID:(int)pid channels:(UInt32)channels fileURL:(NSURL *)url error:(NSError **)error {
    CaptureChannel *ch = [CaptureChannel new];
    ch->pid = pid;
    BOOL isMic = (pid == kATAudioTapDescriptionPIDMicrophone);

    AVAudioFormat *af = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                         sampleRate:kTapSampleRate
                                                           channels:channels interleaved:YES];
    ch->format = *([af streamDescription]);

    // 官方 call-recorder.mm：initTapInternalWithFormat (iOS16+) + qtob
    ATAudioTapDescription *desc = nil;
    if ([ATAudioTapDescription instancesRespondToSelector:@selector(initTapInternalWithFormat:PIDs:)]) {
        desc = [[ATAudioTapDescription alloc] initTapInternalWithFormat:af PIDs:@[@(pid)]];
    } else {
        desc = [[ATAudioTapDescription alloc] initProcessTapInternalWithFormat:af PID:pid];
    }
    ch->tap = [[ATAudioTap alloc] initWithTapDescription:desc];
    if (!ch->tap) { CRLog(@"★tap创建失败 pid=%d", pid); return nil; }

    OSStatus st = AudioQueueNewInput(&ch->format, RecorderCallback, (__bridge void *)ch,
                                     NULL, NULL, 0x800, &ch->queue);
    if (st != noErr) { CRLog(@"★AudioQueueNewInput pid=%d st=%d", pid, (int)st); return nil; }

    // ★决定性：把 tap 接到队列
    st = AudioQueueSetProperty(ch->queue, kAudioQueueProperty_TapOutputBypass,
                               (__bridge void *)ch->tap, 8);
    CRLog(@"pid=%d(%@) qtob=%d ch=%u", pid, isMic?@"自己":@"对方", (int)st, (unsigned)channels);
    if (st != noErr) return nil;

    CalcBufSize(ch->queue, ch->format, &ch->bufferSize);
    for (int i = 0; i < kNumberOfBuffers; i++) {
        st = AudioQueueAllocateBuffer(ch->queue, ch->bufferSize, &ch->buffers[i]);
        if (st != noErr) return nil;
        AudioQueueEnqueueBuffer(ch->queue, ch->buffers[i], 0, NULL);
    }

    st = AudioFileCreateWithURL((__bridge CFURLRef)url, kAudioFileCAFType, &ch->format,
                                kAudioFileFlags_EraseFile, &ch->audioFile);
    if (st != noErr) { CRLog(@"★CAF创建失败 pid=%d st=%d", pid, (int)st); return nil; }
    ch->currentPacket = 0;

    AudioQueueAddPropertyListener(ch->queue, kAudioQueueProperty_IsRunning, ListenerCallback, (__bridge void *)ch);
    st = AudioQueueStart(ch->queue, NULL);
    CRLog(@"pid=%d AudioQueueStart=%d buf=%u", pid, (int)st, (unsigned)ch->bufferSize);
    if (st != noErr) return nil;
    ch->running = YES;
    return ch;
}

- (BOOL)startWithChannel:(TRChannel)channel fileURL:(NSURL *)fileURL error:(NSError **)error {
    if (_recording) return YES;
    CRLog(@"========== 开始录音 v5 (双路混音) iOS=%@ ==========", [UIDevice currentDevice].systemVersion);
    _channel = channel;
    _outURL = fileURL;

    NSString *base = [[fileURL lastPathComponent] stringByDeletingPathExtension];
    NSURL *dir = [fileURL URLByDeletingLastPathComponent];
    NSURL *micURL = [dir URLByAppendingPathComponent:[base stringByAppendingString:@"_mic.caf"]];
    NSURL *spkURL = [dir URLByAppendingPathComponent:[base stringByAppendingString:@"_spk.caf"]];
    self->_micURL = micURL; self->_spkURL = spkURL;

    // tap 通道不激活 AVAudioSession（靠 CanRecordWithoutSessionActivation 权限）
    if (channel == TRChannelMicrophone || channel == TRChannelSpeaker) {
        // 单路也用 tap 配方，行为一致
    }

    if (channel == TRChannelSystemAudio || channel == TRChannelMicrophone) {
        _mic = [self startChannelWithPID:kATAudioTapDescriptionPIDMicrophone channels:1 fileURL:micURL error:error];
        if (!_mic) { [self fail:@"麦克风通道启动失败" error:error]; return NO; }
    }
    if (channel == TRChannelSystemAudio || channel == TRChannelSpeaker) {
        _spk = [self startChannelWithPID:kATAudioTapDescriptionPIDSpeaker channels:2 fileURL:spkURL error:error];
        if (!_spk) { [self fail:@"扬声器通道启动失败" error:error]; return NO; }
    }
    _recording = YES;
    return YES;
}

- (void)stop {
    if (!_recording) { [self cleanup]; return; }
    CRLog(@"停止采集：mic回调=%d 字节=%llu 峰值=%.3f | spk回调=%d 字节=%llu 峰值=%.3f",
          _mic?_mic->callbacks:0, _mic?_mic->totalBytes:0, _mic?_mic->peak:0,
          _spk?_spk->callbacks:0, _spk?_spk->totalBytes:0, _spk?_spk->peak:0);

    // 先停队列（同步），再关文件，保证数据写全
    [self stopChannel:_mic];
    [self stopChannel:_spk];
    _recording = NO;

    NSURL *in1 = self->_micURL;
    NSURL *in2 = (_channel == TRChannelSystemAudio && self->_spkURL) ? self->_spkURL : nil;
    Float64 sr = SampleRateForQuality(_quality);
    UInt32 br = BitrateForQuality(_quality);
    NSString *err = nil;
    CRLog(@"混音：%@ + %@ -> %@ @%.0fHz %ubps", in1.lastPathComponent, in2.lastPathComponent,
          _outURL.lastPathComponent, sr, (unsigned)br);
    BOOL ok = MixCAFs(in1, in2, _outURL, sr, br, &err);
    if (!ok) {
        CRLog(@"★混音失败：%@", err);
        if ([_delegate respondsToSelector:@selector(recorderDidFailWithMessage:)])
            [_delegate recorderDidFailWithMessage:err ?: @"混音失败"];
    } else {
        CRLog(@"✅混音完成：%@", _outURL.lastPathComponent);
        if ([_delegate respondsToSelector:@selector(recorderDidFinishWithURL:micLevel:speakerLevel:)])
            [_delegate recorderDidFinishWithURL:_outURL micLevel:_mic?_mic->peak:0 speakerLevel:_spk?_spk->peak:0];
    }
    [self cleanup];
}

- (void)stopChannel:(CaptureChannel *)ch {
    if (!ch) return;
    ch->running = NO;
    if (ch->queue) { AudioQueueStop(ch->queue, true); AudioQueueRemovePropertyListener(ch->queue, kAudioQueueProperty_IsRunning, ListenerCallback, (__bridge void *)ch); }
    if (ch->audioFile) { AudioFileClose(ch->audioFile); ch->audioFile = 0; }
    if (ch->queue) { AudioQueueDispose(ch->queue, true); ch->queue = NULL; }
    ch->tap = nil;
}

- (void)fail:(NSString *)msg error:(NSError **)error {
    CRLog(@"★%@", msg);
    if (error) *error = [NSError errorWithDomain:@"RecorderEngine" code:-1
                                       userInfo:@{NSLocalizedDescriptionKey:msg}];
    [self stopChannel:_mic]; [self stopChannel:_spk];
    _mic = nil; _spk = nil; _recording = NO;
}

- (void)cleanup {
    [self stopChannel:_mic]; [self stopChannel:_spk];
    _mic = nil; _spk = nil; _recording = NO;
}

- (void)dealloc { [self cleanup]; }

@end
