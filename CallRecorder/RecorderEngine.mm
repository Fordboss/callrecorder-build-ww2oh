#import "RecorderEngine.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <stdio.h>

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

// 写进用户能导出的 appcall_monitor.log：把写盘/混音内部数字暴露出来，一次定位
static void CRAppLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], body];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [docs stringByAppendingPathComponent:@"appcall_monitor.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [[line dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES]; }
}

static UInt64 CRFileSize(NSURL *u) {
    if (!u) return 0;
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:u.path error:nil];
    return [a[NSFileSize] unsignedLongLongValue];
}

#pragma mark - v9.2 纯 PCM WAV 直写（不经过任何编码器）
// 之前的 AAC/m4a 由 ExtAudioFile 编码，真机两版都出现「电平有值、文件静音」。
// WAV 是唯一「回调里有 PCM，文件里就一定有声音」的格式：
// 没有 converter、没有 packet desc、没有二次打开、没有 flush 语义。

static void CRPut16(FILE *f, UInt16 v) {
    UInt8 b[2] = { (UInt8)(v & 0xff), (UInt8)((v >> 8) & 0xff) };
    fwrite(b, 1, 2, f);
}
static void CRPut32(FILE *f, UInt32 v) {
    UInt8 b[4] = { (UInt8)(v & 0xff), (UInt8)((v >> 8) & 0xff),
                   (UInt8)((v >> 16) & 0xff), (UInt8)((v >> 24) & 0xff) };
    fwrite(b, 1, 4, f);
}
// 写 44 字节标准 RIFF/WAVE 头，长度字段先占位，结束时回填
static void CRWavHeader(FILE *f, UInt32 rate, UInt16 channels) {
    fwrite("RIFF", 1, 4, f); CRPut32(f, 36);
    fwrite("WAVE", 1, 4, f); fwrite("fmt ", 1, 4, f);
    CRPut32(f, 16); CRPut16(f, 1); CRPut16(f, channels);
    CRPut32(f, rate); CRPut32(f, rate * channels * 2);
    CRPut16(f, channels * 2); CRPut16(f, 16);
    fwrite("data", 1, 4, f); CRPut32(f, 0);
}
static void CRWavFinalize(FILE *f, UInt64 frames, UInt16 channels) {
    if (!f) return;
    UInt64 dataBytes = frames * channels * 2;
    if (fseek(f, 4, SEEK_SET) == 0)  CRPut32(f, (UInt32)(36 + dataBytes));
    if (fseek(f, 40, SEEK_SET) == 0) CRPut32(f, (UInt32)dataBytes);
    fflush(f);
}
// 两个单声道 WAV 纯字节交叉合成一个立体声 WAV（左=自己 右=对方）。
// 全程只做 fread/fwrite，不涉及任何编解码或格式转换。
static BOOL CRMixWavToStereo(NSURL *aURL, NSURL *bURL, NSURL *outURL,
                             UInt32 rate, UInt64 *outFrames, UInt64 *outNonZero) {
    FILE *fa = fopen(aURL.path.fileSystemRepresentation, "rb");
    FILE *fb = fopen(bURL.path.fileSystemRepresentation, "rb");
    if (!fa || !fb) { if (fa) fclose(fa); if (fb) fclose(fb); return NO; }
    if (fseek(fa, 44, SEEK_SET) != 0 || fseek(fb, 44, SEEK_SET) != 0) {
        fclose(fa); fclose(fb); return NO;
    }
    [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
    FILE *fo = fopen(outURL.path.fileSystemRepresentation, "wb");
    if (!fo) { fclose(fa); fclose(fb); return NO; }
    CRWavHeader(fo, rate, 2);
    SInt16 x = 0, y = 0, pair[2];
    UInt64 frames = 0, nonZero = 0;
    while (fread(&x, sizeof(SInt16), 1, fa) == 1) {
        if (fread(&y, sizeof(SInt16), 1, fb) != 1) y = 0;
        pair[0] = x; pair[1] = y;
        fwrite(pair, sizeof(SInt16), 2, fo);
        if (x != 0 || y != 0) nonZero++;
        frames++;
    }
    CRWavFinalize(fo, frames, 2);
    fclose(fa); fclose(fb); fclose(fo);
    if (outFrames)  *outFrames  = frames;
    if (outNonZero) *outNonZero = nonZero;
    return frames > 0;
}

#pragma mark - 单路采集通道

@interface CaptureChannel : NSObject {
@public
    AudioStreamBasicDescription format;
    AudioQueueRef               queue;
    AudioQueueBufferRef         buffers[kNumberOfBuffers];
    AudioFileID                 audioFile;
    ExtAudioFileRef             extFile;   // v9.1 遗留（手动模式保留），v9.2 自动模式不再使用
    FILE                       *wav;       // v9.2: PCM WAV 直写（无编码器）
    SInt16                     *wavScratch;
    UInt32                      wavScratchCap;
    UInt32                      wavDown;   // 整数抽取系数 1/2/4
    UInt32                      wavRate;   // 输出采样率
    double                      wavAcc;
    UInt32                      wavAccN;
    UInt64                      wavFrames;
    UInt64                      wavNonZero;
    UInt32                      bufferSize;
    SInt64                      currentPacket;
    int                         pid;
    ATAudioTap                 *tap;
    float                       peak;      // 实时峰值（可被诊断消费清零）
    float                       peakEver;  // 累计峰值（永不清零，停止时择优用）
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
#define CRMAX(a,b) ((a)>(b)?(a):(b))
static BOOL MixCAFs(NSURL *in1, NSURL *in2, NSURL *outURL, Float64 outSR, UInt64 *outFrames, NSString **errMsg) {
    // 所有变量在顶部声明，避免 C++ 下 goto 跨越初始化
    ExtAudioFileRef f1 = NULL, f2 = NULL, fout = NULL;
    AudioStreamBasicDescription clientFmt = {0}, outFmt = {0}, writeFmt = {0};
    AudioChannelLayout layout = {0};
    SInt16 *b1 = NULL, *b2 = NULL, *bo = NULL;
    AudioBufferList abl1 = {0}, abl2 = {0}, ablo = {0};
    OSStatus st = noErr;
    BOOL ok = NO;
    UInt32 sz = 0;
    UInt64 framesTotal = 0;
    const UInt32 framesPerBuf = 8192;

    do {
        st = ExtAudioFileOpenURL((__bridge CFURLRef)in1, &f1);
        if (st != noErr) { if (errMsg) *errMsg = [NSString stringWithFormat:@"打开输入1失败 %d", (int)st]; break; }
        if (in2) {
            st = ExtAudioFileOpenURL((__bridge CFURLRef)in2, &f2);
            if (st != noErr) { if (errMsg) *errMsg = [NSString stringWithFormat:@"打开输入2失败 %d", (int)st]; break; }
        }

        // 读取端：统一转成 Int16 / 目标采样率 / 单声道
        clientFmt.mSampleRate       = outSR;
        clientFmt.mFormatID         = kAudioFormatLinearPCM;
        clientFmt.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        clientFmt.mFramesPerPacket  = 1;
        clientFmt.mChannelsPerFrame = 1;
        clientFmt.mBitsPerChannel   = 16;
        clientFmt.mBytesPerFrame    = 2;
        clientFmt.mBytesPerPacket   = 2;
        OSStatus cs = ExtAudioFileSetProperty(f1, kExtAudioFileProperty_ClientDataFormat, sizeof(clientFmt), &clientFmt);
        if (cs != noErr) { if (errMsg) *errMsg = [NSString stringWithFormat:@"输入1格式转换失败 %d", (int)cs]; break; }
        if (f2) {
            cs = ExtAudioFileSetProperty(f2, kExtAudioFileProperty_ClientDataFormat, sizeof(clientFmt), &clientFmt);
            if (cs != noErr) { if (errMsg) *errMsg = [NSString stringWithFormat:@"输入2格式转换失败 %d", (int)cs]; break; }
        }

        // 输出：AAC / 立体声 / 目标采样率（码率由系统按采样率自动选，降采样率即减小体积）
        outFmt.mSampleRate       = outSR;
        outFmt.mFormatID         = kAudioFormatMPEG4AAC;
        outFmt.mChannelsPerFrame = 2;
        sz = sizeof(outFmt);
        st = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL, &sz, &outFmt);
        if (st != noErr) { if (errMsg) *errMsg = [NSString stringWithFormat:@"FormatInfo失败 %d", (int)st]; break; }

        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
        st = ExtAudioFileCreateWithURL((__bridge CFURLRef)outURL, kAudioFileM4AType, &outFmt, &layout,
                                       kAudioFileFlags_EraseFile, &fout);
        if (st != noErr) { if (errMsg) *errMsg = [NSString stringWithFormat:@"创建m4a失败 %d", (int)st]; break; }

        // 写入端用 Int16 立体声，由 ExtAudioFile 编码为 AAC
        writeFmt = clientFmt;
        writeFmt.mChannelsPerFrame = 2;
        writeFmt.mBytesPerFrame    = 4;
        writeFmt.mBytesPerPacket   = 4;
        cs = ExtAudioFileSetProperty(fout, kExtAudioFileProperty_ClientDataFormat, sizeof(writeFmt), &writeFmt);
        if (cs != noErr) { if (errMsg) *errMsg = [NSString stringWithFormat:@"输出格式设置失败 %d", (int)cs]; break; }

        b1 = (SInt16 *)calloc(framesPerBuf, sizeof(SInt16));
        b2 = (SInt16 *)calloc(framesPerBuf, sizeof(SInt16));
        bo = (SInt16 *)calloc(framesPerBuf * 2, sizeof(SInt16));
        if (!b1 || !b2 || !bo) { if (errMsg) *errMsg = @"内存分配失败"; break; }

        abl1.mNumberBuffers = 1; abl1.mBuffers[0].mNumberChannels = 1;
        abl1.mBuffers[0].mDataByteSize = framesPerBuf * sizeof(SInt16); abl1.mBuffers[0].mData = b1;
        abl2.mNumberBuffers = 1; abl2.mBuffers[0].mNumberChannels = 1;
        abl2.mBuffers[0].mDataByteSize = framesPerBuf * sizeof(SInt16); abl2.mBuffers[0].mData = b2;
        ablo.mNumberBuffers = 1; ablo.mBuffers[0].mNumberChannels = 2;
        ablo.mBuffers[0].mDataByteSize = framesPerBuf * 2 * sizeof(SInt16); ablo.mBuffers[0].mData = bo;

        while (1) {
            // ExtAudioFileRead 会改写 mDataByteSize 为实际字节数，下一轮必须还原成缓冲区容量
            abl1.mBuffers[0].mDataByteSize = framesPerBuf * sizeof(SInt16);
            abl2.mBuffers[0].mDataByteSize = framesPerBuf * sizeof(SInt16);
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
                SInt16 r = f2 ? ((i < n2) ? b2[i] : 0) : l;
                bo[i*2]   = l;   // 左：麦克风（自己）
                bo[i*2+1] = r;   // 右：扬声器（对方）
            }
            ablo.mBuffers[0].mDataByteSize = frames * 2 * sizeof(SInt16);
            st = ExtAudioFileWrite(fout, frames, &ablo);
            if (st != noErr) { CRLog(@"混音写输出失败 %d", (int)st); break; }
            framesTotal += frames;
        }
        ok = YES;
    } while (0);

    free(b1); free(b2); free(bo);
    if (f1) ExtAudioFileDispose(f1);
    if (f2) ExtAudioFileDispose(f2);
    if (fout) ExtAudioFileDispose(fout);
    if (outFrames) *outFrames = framesTotal;
    CRAppLog(@"[混音] 读出总帧数=%llu 结果=%@ %@", framesTotal, ok ? @"完成" : @"失败", errMsg ? *errMsg : @"");
    return ok;
}

#pragma mark - 引擎

@interface RecorderEngine () {
    CaptureChannel *_mic;
    CaptureChannel *_spk;
    CaptureChannel *_app;        // v9: 对方路（微信/QQ 真实进程 PID 的 app-tap）
    CaptureChannel *_sys;        // v9: -2 系统混音诊断/兜底路
    CaptureChannel *_monMic;     // 监测通道（只算电平，不写盘）
    CaptureChannel *_monSpk;
    NSURL *_outURL;
    NSURL *_micURL;
    NSURL *_spkURL;
    NSURL *_appURL;
    NSURL *_sysURL;
    NSURL *_appWavURL;      // v9.2: 对方路临时 WAV
    NSURL *_sysWavURL;      // v9.2: 系统混音路临时 WAV
    TRChannel _channel;
    BOOL _recording;
    BOOL _monitoring;
    BOOL _autoMode;
    BOOL _appTapActive;
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
    // v9.2 WAV 直写：44100 / ÷2 / ÷4，实际输出采样率
    switch (q) {
        case TRQualityHigh:   return @"高清 44.1kHz · 约 5.3 MB/分";
        case TRQualityNormal: return @"标准 22.05kHz · 约 2.6 MB/分";
        case TRQualitySmall:
        default:              return @"省空间 11.025kHz · 约 1.3 MB/分";
    }
}

- (NSInteger)outputSampleRate {
    UInt32 down = (_quality == TRQualityHigh) ? 1 : ((_quality == TRQualityNormal) ? 2 : 4);
    return (NSInteger)(kTapSampleRate / down);
}
- (NSURL *)debugLogURL { return CRDebugLogURL(); }
- (BOOL)isRecording { return _recording; }
- (float)peakLevel { float m = _mic ? _mic->peak : 0; CaptureChannel *s = _autoMode ? _app : _spk; return m > (s?s->peak:0) ? m : (s?s->peak:0); }
- (float)micLevel { return _mic ? _mic->peak : 0; }
- (float)speakerLevel { CaptureChannel *s = _autoMode ? _app : _spk; return s ? s->peak : 0; }
- (float)appLevel { return _app ? _app->peak : 0; }
- (float)systemLevel { return _sys ? _sys->peak : 0; }
- (BOOL)appTapActive { return _appTapActive; }

// 取 v9 三路电平并清零（用于每 5 秒诊断，判断哪条路真的抓到声音）
- (void)consumeAutoLevelsMic:(float *)mic app:(float *)app sys:(float *)sys {
    float m = _mic ? _mic->peak : 0;
    float a = _app ? _app->peak : 0;
    float s = _sys ? _sys->peak : 0;
    if (_mic) _mic->peak = 0;
    if (_app) _app->peak = 0;
    if (_sys) _sys->peak = 0;
    if (mic) *mic = m; if (app) *app = a; if (sys) *sys = s;
}

#pragma mark 采集回调

static void RecorderCallback(void *ptr, AudioQueueRef aq, AudioQueueBufferRef buffer,
                             const AudioTimeStamp *ts, UInt32 numPackets,
                             const AudioStreamPacketDescription *packetDesc) {
    CaptureChannel *ch = (__bridge CaptureChannel *)ptr;
    if (numPackets == 0 && ch->format.mBytesPerPacket != 0)
        numPackets = buffer->mAudioDataByteSize / ch->format.mBytesPerPacket;

    // audioFile==0 表示监测模式：只算电平不写盘
    if (ch->audioFile) {
        OSStatus st = AudioFileWritePackets(ch->audioFile, false, buffer->mAudioDataByteSize,
                                            packetDesc, ch->currentPacket, &numPackets, buffer->mAudioData);
        if (st == noErr) ch->currentPacket += numPackets;
        else if (ch->callbacks <= 3) { CRLog(@"写盘失败 pid=%d st=%d", ch->pid, (int)st); CRAppLog(@"[写盘] CAF失败 pid=%d st=%d", ch->pid, (int)st); }
    }

    // v9.1 保底：同一份 PCM 直接交给 ExtAudioFile 编码成 AAC/m4a。
    // 这条链路不依赖 CAF 头、不依赖二次打开、不依赖格式转换读取 —— 回调有数据，文件就有声音。
    if (ch->extFile && buffer->mAudioDataByteSize > 0 && ch->format.mBytesPerFrame > 0) {
        AudioBufferList abl = {0};
        abl.mNumberBuffers = 1;
        abl.mBuffers[0].mNumberChannels = ch->format.mChannelsPerFrame;
        abl.mBuffers[0].mDataByteSize = buffer->mAudioDataByteSize;
        abl.mBuffers[0].mData = buffer->mAudioData;
        UInt32 frames = buffer->mAudioDataByteSize / ch->format.mBytesPerFrame;
        OSStatus st = ExtAudioFileWrite(ch->extFile, frames, &abl);
        if (st != noErr && ch->callbacks <= 3) { CRLog(@"直写m4a失败 pid=%d st=%d", ch->pid, (int)st); CRAppLog(@"[写盘] 直写m4a失败 st=%d", (int)st); }
    }

    Float32 *s = (Float32 *)buffer->mAudioData;
    UInt32 count = buffer->mAudioDataByteSize / sizeof(Float32);
    for (UInt32 i = 0; i < count; i++) {
        Float32 a = fabsf(s[i]);
        if (a > ch->peak) ch->peak = a;
        if (a > ch->peakEver) ch->peakEver = a;
        ch->sumSq += (double)s[i] * s[i];
        ch->sampleCount++;
    }
    // v9.2 ★决定性：同一份 PCM 直接写标准 WAV（Float32→Int16 整数抽取），
    // 不经过 AAC 编码器、不经过 CAF、不经过二次打开。回调有数据 → 文件里就必然有波形。
    if (ch->wav && ch->format.mBytesPerFrame > 0) {
        UInt32 inCh = ch->format.mChannelsPerFrame ? ch->format.mChannelsPerFrame : 1;
        UInt32 frames = buffer->mAudioDataByteSize / ch->format.mBytesPerFrame;
        UInt32 outN = 0;
        for (UInt32 i = 0; i < frames && outN < ch->wavScratchCap; i++) {
            double v = 0;
            for (UInt32 c = 0; c < inCh; c++) v += s[i * inCh + c];
            v /= inCh;                       // 立体声先合成为单声道
            ch->wavAcc += v; ch->wavAccN++;  // 累加平均 = 简易低通 + 整数抽取
            if (ch->wavAccN >= ch->wavDown) {
                double avg = ch->wavAcc / ch->wavAccN;
                ch->wavAcc = 0; ch->wavAccN = 0;
                if (avg > 1.0) avg = 1.0; else if (avg < -1.0) avg = -1.0;
                SInt16 pcm = (SInt16)(avg * 32767.0);
                ch->wavScratch[outN++] = pcm;
                if (pcm != 0) ch->wavNonZero++;
            }
        }
        if (outN > 0) {
            fwrite(ch->wavScratch, sizeof(SInt16), outN, ch->wav);
            ch->wavFrames += outN;
        }
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
    return [self startChannelWithPIDs:@[@(pid)] channels:channels fileURL:url labelPid:pid error:error];
}

// v9 关键：PIDs 是数组 —— 可一次 tap 多个「真实进程 PID」（官方 app-tap 配方）
- (CaptureChannel *)startChannelWithPIDs:(NSArray<NSNumber *> *)pids channels:(UInt32)channels fileURL:(NSURL *)url labelPid:(int)pid error:(NSError **)error {
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
        desc = [[ATAudioTapDescription alloc] initTapInternalWithFormat:af PIDs:pids];
    } else {
        // iOS 15 仅有单 PID 版本，取第一个
        desc = [[ATAudioTapDescription alloc] initProcessTapInternalWithFormat:af PID:pids.firstObject.intValue];
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

    // url==nil → 监测模式：不创建文件，回调只更新电平
    if (url) {
        st = AudioFileCreateWithURL((__bridge CFURLRef)url, kAudioFileCAFType, &ch->format,
                                    kAudioFileFlags_EraseFile, &ch->audioFile);
        if (st != noErr) { CRLog(@"★CAF创建失败 pid=%d st=%d", pid, (int)st); return nil; }
    } else {
        ch->audioFile = 0;
    }
    ch->currentPacket = 0;

    AudioQueueAddPropertyListener(ch->queue, kAudioQueueProperty_IsRunning, ListenerCallback, (__bridge void *)ch);
    st = AudioQueueStart(ch->queue, NULL);
    CRLog(@"pid=%d AudioQueueStart=%d buf=%u", pid, (int)st, (unsigned)ch->bufferSize);
    if (st != noErr) return nil;
    ch->running = YES;
    return ch;
}

// v9.1 保底：给通道挂一份「回调直写 AAC m4a」的输出。
// 用 tap 原生 44.1kHz / 单声道，只有 Float32→AAC 一步编码，不重采样、不二次读盘。
- (BOOL)attachDirectOutput:(NSURL *)url toChannel:(CaptureChannel *)ch {
    if (!url || !ch) return NO;
    AudioStreamBasicDescription outDesc = {0};
    outDesc.mSampleRate = kTapSampleRate;
    outDesc.mFormatID = kAudioFormatMPEG4AAC;
    outDesc.mChannelsPerFrame = ch->format.mChannelsPerFrame;
    UInt32 sz = sizeof(outDesc);
    OSStatus st = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL, &sz, &outDesc);
    if (st != noErr) { CRAppLog(@"[保底] AAC FormatInfo失败 st=%d", (int)st); return NO; }

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtURL:url error:nil];
    st = ExtAudioFileCreateWithURL((__bridge CFURLRef)url, kAudioFileM4AType, &outDesc, NULL,
                                   kAudioFileFlags_EraseFile, &ch->extFile);
    if (st != noErr || !ch->extFile) {
        CRAppLog(@"[保底] 创建m4a失败 st=%d", (int)st);
        ch->extFile = NULL; return NO;
    }
    st = ExtAudioFileSetProperty(ch->extFile, kExtAudioFileProperty_ClientDataFormat,
                                 sizeof(ch->format), &ch->format);
    if (st != noErr) {
        CRAppLog(@"[保底] ClientDataFormat失败 st=%d", (int)st);
        ExtAudioFileDispose(ch->extFile); ch->extFile = NULL;
        [fm removeItemAtURL:url error:nil];
        return NO;
    }
    CRAppLog(@"[保底] 直写m4a已挂接 %.0fHz/%uch → %@", outDesc.mSampleRate,
             (unsigned)outDesc.mChannelsPerFrame, url.lastPathComponent);
    return YES;
}

// v9.2 保底：给通道挂一份「回调直写 PCM WAV」输出。
// down=1/2/4 → 44100/22050/11025 Hz（全部整数倍，无重采样插值误差）。
- (BOOL)attachWavOutput:(NSURL *)url toChannel:(CaptureChannel *)ch down:(UInt32)down {
    if (!url || !ch || down < 1) return NO;
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    FILE *f = fopen(url.path.fileSystemRepresentation, "wb");
    if (!f) { CRAppLog(@"[WAV] 打开失败 %@", url.lastPathComponent); return NO; }
    UInt32 rate = (UInt32)(kTapSampleRate / down);
    CRWavHeader(f, rate, 1);
    ch->wav = f;
    ch->wavDown = down;
    ch->wavRate = rate;
    ch->wavScratchCap = ch->bufferSize / (ch->format.mBytesPerFrame ?: 4) + 16;
    ch->wavScratch = (SInt16 *)calloc(ch->wavScratchCap, sizeof(SInt16));
    if (!ch->wavScratch) {
        fclose(f); ch->wav = NULL;
        CRAppLog(@"[WAV] 缓冲分配失败"); return NO;
    }
    CRAppLog(@"[WAV] 已挂接 %.0f→%uHz/%u ÷%u → %@",
             kTapSampleRate, (unsigned)rate, (unsigned)ch->format.mChannelsPerFrame,
             (unsigned)down, url.lastPathComponent);
    return YES;
}

// v9：官方免费版配方 —— 按微信/QQ 真实进程 PID 做 app-tap
- (BOOL)startAutoWithAppPIDs:(NSArray<NSNumber *> *)appPIDs
                     fileURL:(NSURL *)fileURL
                       error:(NSError **)error {
    if (_recording) return YES;
    if (_monitoring) [self stopMonitoring];
    _autoMode = YES;
    _appTapActive = NO;
    CRLog(@"===== 开始 v9 app-tap 录音 iOS=%@ | PIDs=%@ =====",
          [UIDevice currentDevice].systemVersion, appPIDs);
    _channel = TRChannelSystemAudio;
    _outURL = fileURL;

    NSString *base = [[fileURL lastPathComponent] stringByDeletingPathExtension];
    NSURL *dir = [fileURL URLByDeletingLastPathComponent];
    // v9.2：自动模式彻底不用 CAF / AAC / ExtAudioFile，三路各自直接写 WAV
    _micURL = nil; _appURL = nil; _sysURL = nil; _spkURL = nil;
    _appWavURL = [dir URLByAppendingPathComponent:[base stringByAppendingString:@"_app.wav"]];
    _sysWavURL = [dir URLByAppendingPathComponent:[base stringByAppendingString:@"_sys.wav"]];
    // 44100 → ÷4=11025 / ÷2=22050 / ÷1=44100，全部整数抽取，无插值误差
    UInt32 down = (_quality == TRQualityHigh) ? 1 : ((_quality == TRQualityNormal) ? 2 : 4);

    // 自己：麦克风 -3 → 直接写保底 WAV（最终主文件就是它，全程不覆盖、不转码）
    _mic = [self startChannelWithPID:kATAudioTapDescriptionPIDMicrophone channels:1 fileURL:nil error:error];
    if (!_mic) { [self fail:@"麦克风通道启动失败" error:error]; return NO; }
    BOOL wavOK = [self attachWavOutput:_outURL toChannel:_mic down:down];
    CRAppLog(@"[WAV] 麦克风保底直写 %@", wavOK ? @"成功" : @"失败");
    if (!wavOK) { [self fail:@"无法创建 WAV 文件" error:error]; return NO; }

    // 对方：真实进程 PID app-tap（临时 WAV，停止时择优）
    if (appPIDs.count > 0) {
        _app = [self startChannelWithPIDs:appPIDs channels:2 fileURL:nil
                                 labelPid:appPIDs.firstObject.intValue error:nil];
        if (_app) {
            _appTapActive = YES;
            [self attachWavOutput:_appWavURL toChannel:_app down:down];
            CRLog(@"★app-tap 真实PID 启动成功: %@", appPIDs);
        }
    }
    if (!_app) {
        CRLog(@"app-tap 不可用 → 回退 -2 系统混音");
        _app = [self startChannelWithPID:kATAudioTapDescriptionPIDSpeaker channels:2 fileURL:nil error:nil];
        if (_app) [self attachWavOutput:_appWavURL toChannel:_app down:down];
    }

    // 诊断/兜底：-2 系统混音。仅当 app-tap 成功时再开（避免同 PID 双队列）
    if (_appTapActive) {
        _sys = [self startChannelWithPID:kATAudioTapDescriptionPIDSpeaker channels:2 fileURL:nil error:nil];
        if (_sys) [self attachWavOutput:_sysWavURL toChannel:_sys down:down];
    } else {
        _sys = nil;
    }

    _recording = YES;
    CRLog(@"v9 通道: mic=%@ app=%@(真实PID=%@) sys=%@",
          _mic?@"OK":@"FAIL", _app?@"OK":@"FAIL",
          _appTapActive?@"Y":@"N", _sys?@"OK":@"N/A");
    return _mic != nil;
}

- (BOOL)startWithChannel:(TRChannel)channel fileURL:(NSURL *)fileURL error:(NSError **)error {
    if (_recording) return YES;
    // 录音前先停监测，避免同 PID 两路 tap 冲突
    if (_monitoring) [self stopMonitoring];
    _autoMode = NO;
    CRLog(@"========== 开始录音 v6 (双路混音+电平触发) iOS=%@ ==========", [UIDevice currentDevice].systemVersion);
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

    // 先停队列（同步），再关 CAF 与直写 m4a，保证数据写全
    [self stopChannel:_mic];
    [self stopChannel:_spk];
    [self stopChannel:_app];
    [self stopChannel:_sys];
    _recording = NO;

    NSFileManager *fm = [NSFileManager defaultManager];

    // ============ v9.2 自动模式：纯 WAV 路径，绝不触碰 AAC / CAF / MixCAFs ============
    if (_autoMode) {
        UInt64 micFrames   = _mic ? _mic->wavFrames   : 0;
        UInt64 micNonZero  = _mic ? _mic->wavNonZero  : 0;
        UInt64 appNonZero  = _app ? _app->wavNonZero  : 0;
        UInt64 sysNonZero  = _sys ? _sys->wavNonZero  : 0;
        UInt64 micBytes    = CRFileSize(_outURL);
        UInt32 rate        = _mic ? _mic->wavRate : 11025;
        CRAppLog(@"[停止] WAV 主文件: 帧=%llu 非零样本=%llu 字节=%llu %uHz",
                 micFrames, micNonZero, micBytes, (unsigned)rate);
        CRAppLog(@"[停止] WAV 临时: app非零=%llu(%lluB) sys非零=%llu(%lluB) | 峰值 app=%.4f sys=%.4f",
                 appNonZero, CRFileSize(_appWavURL), sysNonZero, CRFileSize(_sysWavURL),
                 _app ? _app->peakEver : 0, _sys ? _sys->peakEver : 0);

        // 对方路择优：真机已证明 -2 系统混音才是主路，按累计峰值选
        float appPeak = _app ? _app->peakEver : 0;
        float sysPeak = _sys ? _sys->peakEver : 0;
        NSURL *other = nil;
        if (_appTapActive && _sys && sysPeak >= appPeak && CRFileSize(_sysWavURL) > 44)
            other = _sysWavURL;
        else if (CRFileSize(_appWavURL) > 44)
            other = _appWavURL;
        else if (CRFileSize(_sysWavURL) > 44)
            other = _sysWavURL;

        NSString *base = [[_outURL lastPathComponent] stringByDeletingPathExtension];
        NSURL *dir = [_outURL URLByDeletingLastPathComponent];
        NSURL *stereoURL = [dir URLByAppendingPathComponent:[base stringByAppendingString:@"_双方.wav"]];
        if (other && micBytes > 44) {
            UInt64 frames = 0, nz = 0;
            BOOL ok = CRMixWavToStereo(_outURL, other, stereoURL, rate, &frames, &nz);
            CRAppLog(@"[停止] 立体声合成=%@ 帧=%llu 非零=%llu → %@",
                     ok ? @"成功" : @"失败", frames, nz, stereoURL.lastPathComponent);
            if (!ok || nz == 0) [fm removeItemAtURL:stereoURL error:nil];
        }
        CRAppLog(@"[停止] ★保底 WAV 原样保留: %@ (%lluB)，立体声另存同名 _双方.wav",
                 _outURL.lastPathComponent, micBytes);

        [fm removeItemAtURL:_appWavURL error:nil];
        [fm removeItemAtURL:_sysWavURL error:nil];

        if (micBytes > 44 && micNonZero > 0) {
            CRLog(@"录音完成(WAV)：%@ (%lluB 非零=%llu)", _outURL.lastPathComponent, micBytes, micNonZero);
            if ([_delegate respondsToSelector:@selector(recorderDidFinishWithURL:micLevel:speakerLevel:)])
                [_delegate recorderDidFinishWithURL:_outURL
                                          micLevel:_mic ? _mic->peakEver : 0
                                      speakerLevel:_app ? _app->peakEver : 0];
        } else {
            CRAppLog(@"[停止] ★WAV 内无声音样本 —— 采集回调未写入数据");
            if ([_delegate respondsToSelector:@selector(recorderDidFailWithMessage:)])
                [_delegate recorderDidFailWithMessage:@"WAV 无声音数据"];
        }
        [self cleanup];
        return;
    }

    // ============ 手动录音模式：沿用原 CAF→MixCAFs→m4a 链路 ============
    UInt64 micCafBytes = CRFileSize(_micURL);
    UInt64 appCafBytes = CRFileSize(_appURL);
    UInt64 sysCafBytes = CRFileSize(_sysURL);
    UInt64 directBytes = CRFileSize(_outURL);
    CRAppLog(@"[停止] mic回调=%d 采样字节=%llu 峰值Ever=%.4f | app峰值Ever=%.4f | sys峰值Ever=%.4f",
             _mic ? _mic->callbacks : 0, _mic ? _mic->totalBytes : 0,
             _mic ? _mic->peakEver : 0, _app ? _app->peakEver : 0, _sys ? _sys->peakEver : 0);
    CRAppLog(@"[停止] 文件: 直写m4a=%lluB mic.caf=%lluB app.caf=%lluB sys.caf=%lluB",
             directBytes, micCafBytes, appCafBytes, sysCafBytes);

    NSURL *in1 = self->_micURL;
    NSURL *in2 = nil;
    if (_autoMode) {
        float appPeak = _app ? _app->peakEver : 0;
        float sysPeak = _sys ? _sys->peakEver : 0;
        if (_appTapActive && _sys) {
            in2 = (appPeak >= sysPeak) ? self->_appURL : self->_sysURL;
            CRLog(@"★v9择优: app-tap=%.4f sys混音=%.4f → 采用 %@",
                  appPeak, sysPeak, in2.lastPathComponent);
        } else {
            in2 = self->_appURL ?: self->_spkURL;
            CRLog(@"v9: 采用 %@ (回退路径)", in2.lastPathComponent);
        }
    } else {
        in2 = (_channel == TRChannelSystemAudio && self->_spkURL) ? self->_spkURL : nil;
    }

    NSString *base = [[_outURL lastPathComponent] stringByDeletingPathExtension];
    NSURL *dir = [_outURL URLByDeletingLastPathComponent];
    NSURL *mixTmp  = [dir URLByAppendingPathComponent:[base stringByAppendingString:@"_mix.tmp"]];
    NSURL *backup  = [dir URLByAppendingPathComponent:[base stringByAppendingString:@"_direct.tmp"]];
    [fm removeItemAtURL:mixTmp error:nil];
    [fm removeItemAtURL:backup error:nil];

    Float64 sr = SampleRateForQuality(_quality);
    UInt64 mixFrames = 0;
    NSString *err = nil;
    CRLog(@"混音：%@ + %@ -> %@ @%.0fHz", in1.lastPathComponent, in2.lastPathComponent,
          mixTmp.lastPathComponent, sr);
    BOOL ok = MixCAFs(in1, in2, mixTmp, sr, &mixFrames, &err);
    UInt64 mixBytes = CRFileSize(mixTmp);
    CRAppLog(@"[停止] 混音结果=%@ 输出=%lluB 帧数=%llu %@",
             ok ? @"成功" : @"失败", mixBytes, mixFrames, err ?: @"");

    // 混音成功且确实写出音频帧，才升级为立体声；否则原样保留直写 m4a
    BOOL useMix = NO;
    if (ok && mixFrames > 0 && mixBytes > 1024) {
        NSError *mvErr = nil;
        BOOL hasBackup = (directBytes > 0);   // 手动录音模式没有保底直写文件
        if (hasBackup) [fm moveItemAtURL:_outURL toURL:backup error:nil];
        else [fm removeItemAtURL:_outURL error:nil];
        if ([fm moveItemAtURL:mixTmp toURL:_outURL error:&mvErr]) {
            useMix = YES;
            if (hasBackup) [fm removeItemAtURL:backup error:nil];
            CRAppLog(@"[停止] 采用立体声混音（左=自己 右=对方）%@", hasBackup ? @"，已覆盖保底文件" : @"");
        } else {
            if (hasBackup) [fm moveItemAtURL:backup toURL:_outURL error:nil];
            CRAppLog(@"[停止] 覆盖保底失败，已还原：%@", mvErr.localizedDescription ?: @"");
        }
    }
    if (!useMix) {
        [fm removeItemAtURL:mixTmp error:nil];
        CRAppLog(@"[停止] 保留保底直写 m4a（%lluB），混音结果未采用", directBytes);
    }

    // 三重保底：连直写 m4a 都异常时，留下原始 PCM CAF 供直接播放
    if (CRFileSize(_outURL) < 1024 && micCafBytes > 1024) {
        NSURL *cafOut = [[_outURL URLByDeletingPathExtension] URLByAppendingPathExtension:@"caf"];
        [fm removeItemAtURL:cafOut error:nil];
        [fm copyItemAtURL:_micURL toURL:cafOut error:nil];
        CRAppLog(@"[停止] 注意：保底也为空 → 已保留原始 PCM CAF: %@", cafOut.lastPathComponent);
    }

    UInt64 finalBytes = CRFileSize(_outURL);
    if (finalBytes > 1024) {
        CRLog(@"录音完成：%@ (%lluB)", _outURL.lastPathComponent, finalBytes);
        if ([_delegate respondsToSelector:@selector(recorderDidFinishWithURL:micLevel:speakerLevel:)])
            [_delegate recorderDidFinishWithURL:_outURL micLevel:_mic?_mic->peakEver:0 speakerLevel:_app?_app->peakEver:0];
    } else {
        NSString *msg = err ?: @"输出文件为空";
        CRAppLog(@"[停止] 交付失败：%@", msg);
        if ([_delegate respondsToSelector:@selector(recorderDidFailWithMessage:)])
            [_delegate recorderDidFailWithMessage:msg];
    }

    NSURL *temps[4] = { self->_micURL, self->_spkURL, self->_appURL, self->_sysURL };
    for (int i = 0; i < 4; i++) if (temps[i]) [fm removeItemAtURL:temps[i] error:nil];
    [self cleanup];
}

- (void)stopChannel:(CaptureChannel *)ch {
    if (!ch) return;
    ch->running = NO;
    if (ch->queue) { AudioQueueStop(ch->queue, true); AudioQueueRemovePropertyListener(ch->queue, kAudioQueueProperty_IsRunning, ListenerCallback, (__bridge void *)ch); }
    if (ch->audioFile) { AudioFileClose(ch->audioFile); ch->audioFile = 0; }
    if (ch->extFile) { ExtAudioFileDispose(ch->extFile); ch->extFile = NULL; }
    if (ch->queue) { AudioQueueDispose(ch->queue, true); ch->queue = NULL; }
    // v9.2：所有回调都结束后，回填 WAV 头长度并关闭
    if (ch->wav) { CRWavFinalize(ch->wav, ch->wavFrames, 1); fclose(ch->wav); ch->wav = NULL; }
    if (ch->wavScratch) { free(ch->wavScratch); ch->wavScratch = NULL; }
    ch->tap = nil;
}

- (void)fail:(NSString *)msg error:(NSError **)error {
    CRLog(@"★%@", msg);
    if (error) *error = [NSError errorWithDomain:@"RecorderEngine" code:-1
                                       userInfo:@{NSLocalizedDescriptionKey:msg}];
    [self stopChannel:_mic]; [self stopChannel:_spk];
    [self stopChannel:_app]; [self stopChannel:_sys];
    _mic = nil; _spk = nil; _app = nil; _sys = nil; _recording = NO;
}

- (void)cleanup {
    [self stopChannel:_mic]; [self stopChannel:_spk];
    [self stopChannel:_app]; [self stopChannel:_sys];
    _mic = nil; _spk = nil; _app = nil; _sys = nil; _recording = NO;
}

#pragma mark - 监测模式（电平触发，不写盘）

- (BOOL)startMonitoringWithError:(NSError **)error {
    if (_monitoring) return YES;
    if (_recording) { if (error) *error = [NSError errorWithDomain:@"RecorderEngine" code:-2 userInfo:@{NSLocalizedDescriptionKey:@"录音中不能同时监测"}]; return NO; }
    CRLog(@"===== 启动音频监测 (电平触发) iOS=%@ =====", [UIDevice currentDevice].systemVersion);
    NSError *e1 = nil, *e2 = nil;
    // 麦克风(自己) + 扬声器(对方)，url=nil → 不写盘
    _monMic = [self startChannelWithPID:kATAudioTapDescriptionPIDMicrophone channels:1 fileURL:nil error:&e1];
    _monSpk = [self startChannelWithPID:kATAudioTapDescriptionPIDSpeaker     channels:2 fileURL:nil error:&e2];
    CRLog(@"监测通道 mic=%@ spk=%@ err1=%@ err2=%@", _monMic?@"OK":@"FAIL", _monSpk?@"OK":@"FAIL", e1.localizedDescription, e2.localizedDescription);
    if (!_monMic && !_monSpk) {
        if (error) *error = [NSError errorWithDomain:@"RecorderEngine" code:-3 userInfo:@{NSLocalizedDescriptionKey:@"两个监测通道都创建失败"}];
        return NO;
    }
    _monitoring = YES;
    return YES;
}

- (void)stopMonitoring {
    if (!_monitoring) return;
    [self stopChannel:_monMic]; [self stopChannel:_monSpk];
    _monMic = nil; _monSpk = nil; _monitoring = NO;
    CRLog(@"监测已停止");
}

- (BOOL)isMonitoring { return _monitoring; }
- (float)monitorMicLevel { return _monMic ? _monMic->peak : 0; }
- (float)monitorSpeakerLevel { return _monSpk ? _monSpk->peak : 0; }

- (void)consumeMonitorLevelsMic:(float *)mic speaker:(float *)spk {
    float m = _monMic ? _monMic->peak : 0;
    float s = _monSpk ? _monSpk->peak : 0;
    if (_monMic) _monMic->peak = 0;
    if (_monSpk) _monSpk->peak = 0;
    if (mic) *mic = m;
    if (spk) *spk = s;
}

- (void)dealloc { [self cleanup]; [self stopMonitoring]; }

@end
