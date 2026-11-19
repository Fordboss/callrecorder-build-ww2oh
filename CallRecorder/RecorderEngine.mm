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
    float                       uiPeak;    // v9.6 界面专用峰值（只被界面衰减，不受看门狗清零影响）
    float                       peakEver;  // 累计峰值（永不清零，停止时择优用）
    double                      sumSq;
    UInt64                      sampleCount;
    int                         callbacks;
    UInt64                      totalBytes;
    BOOL                        running;
    BOOL                        stopRequested;   // v9.3: 只有显式停止才不再入队
    char                        wavDir[512];     // v9.5 常驻滚动：目录
    char                        wavStem[128];    // v9.5 常驻滚动：文件名主干
    int                         wavPart;         // v9.5 当前段序号
    UInt64                      wavRollFrames;   // v9.5 滚动阈值（帧）
    BOOL                        wavRolling;      // v9.5 是否启用滚动
    UInt64                      wavSilentFrames; // v9.6 连续静音帧数（断话检测）
    BOOL                        wavHadSound;     // v9.6 本段是否出现过声音
    // v9.6 ★只在有人说话时才落盘：没说话时音频只在内存环形缓冲里转，
    // 一句人声都没有就根本不创建文件（旧版 7×24 录环境音，一天几百个垃圾文件）
    BOOL                        wavLazy;         // 延迟建文件（常驻滚动模式启用）
    SInt16                     *preroll;         // 触发前的预录环形缓冲（约 2 秒）
    UInt32                      prerollCap;
    UInt32                      prerollCount;
    UInt32                      prerollPos;
    UInt32                      soundRun;        // 连续有声块计数（防误触发）
    UInt32                      gateBlockN;      // 当前统计块内的样本数
    UInt32                      gateLoudN;       // 当前统计块内超过门限的样本数
    UInt32                      wavOutN;         // 本次回调待写的样本数
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

// v9.5 ★常驻滚动：队列 / AVAudioSession 全程不重启，只在回调内部换一个 WAV 文件。
// 正在写入的文件带 .part 后缀（列表不显示）；封存时回填头、fclose 再 rename 成 .wav，
// 因此列表里出现的每个文件都是「头已回填、可直接播放」的成品。
//
// v9.6 ★只在真的有人说话时才产生文件。
// 旧版（v9.5 及以前）是「麦克风队列一启动就一直写 WAV」，不管有没有通话 ——
// 用户反馈的「没有通话也一堆文件」就是这么来的：待机 8 小时 = 480 个 WAV 文件。
// 现在的做法：
//   1. 平时 PCM 只进内存里的 2 秒预录环形缓冲（不建文件、不占空间）；
//   2. 一旦检测到连续人声（约 0.6 秒以上超过 -33 dBFS），才把预录缓冲刷进磁盘、
//      新建一个 .wav.part 开始正式录 —— 因此开头几个字不会丢；
//   3. 说完话后静音 15 秒（且本段已录满 8 秒）就封存成 .wav —— 挂断十几秒后文件就落地；
//   4. 满 60 秒强制封存，避免一整通长电话只有一个巨大文件；
//   5. 封存后回到「只进内存」状态，没说话就一直不建文件。
// 结果：没有通话就 0 个文件；真打电话就来一个能播的通话文件。
// 全程静音必须不落地：WAV 是未压缩 PCM，11 kHz 单声道静音也要 1.3 MB/分钟，
// 一天待机能攒出好几个 G。
// 前置声明（这些函数互相引用）
static void CRWavOpenPart(CaptureChannel *ch, BOOL withPreroll);
static void CRWavSeal(CaptureChannel *ch, NSString *reason);
static void CRWavRollIfNeeded(CaptureChannel *ch);

// 封存当前段：回填头 → 改名 .wav → 回到"只进内存"的待机状态
static void CRWavSeal(CaptureChannel *ch, NSString *reason) {
    if (!ch || !ch->wav) return;
    UInt64 frames = ch->wavFrames;
    CRWavFinalize(ch->wav, frames, 1);
    fclose(ch->wav);
    ch->wav = NULL;
    char cur[768], fin[768];
    snprintf(cur, sizeof(cur), "%s/%s_p%03d.wav.part", ch->wavDir, ch->wavStem, ch->wavPart);
    snprintf(fin, sizeof(fin), "%s/%s_p%03d.wav", ch->wavDir, ch->wavStem, ch->wavPart);
    rename(cur, fin);
    int sealed = ch->wavPart;
    ch->wavPart++;
    ch->wavFrames = 0;
    ch->wavNonZero = 0;
    ch->wavSilentFrames = 0;
    ch->wavHadSound = NO;
    ch->soundRun = 0;
    ch->gateBlockN = 0; ch->gateLoudN = 0;
    ch->prerollCount = 0;
    ch->prerollPos = 0;
    CRAppLog(@"[录音] ⏹ 第%d段已封存（%.1f秒, %@）→ 回到待机，没说话就不再建文件",
             sealed, (double)frames / (double)ch->wavRate, reason ?: @"—");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"CallRecorderSegmentRolled" object:nil];
    });
}

// 满 60 秒 / 说完话静音 15 秒 → 封存。没说话（ch->wav == NULL）时永远不触发。
static void CRWavRollIfNeeded(CaptureChannel *ch) {
    if (!ch || !ch->wav || !ch->wavRolling || ch->wavRate == 0) return;
    BOOL full = (ch->wavRollFrames > 0 && ch->wavFrames >= ch->wavRollFrames);
    // 这里不设"至少录满 8 秒"的下限：一通 3 秒的短通话也应该在静音 15 秒后落地，
    // 否则它要一直等到满 60 秒才封存 —— 短通话就又会"挂了没文件"。
    // 碎片问题由「15 秒静音」这个条件自己控制，不需要额外下限。
    BOOL talkEnded = (ch->wavSilentFrames >= (UInt64)(15.0 * ch->wavRate));
    if (full)            CRWavSeal(ch, @"满60秒");
    else if (talkEnded)  CRWavSeal(ch, @"说话结束静音15秒");
}

static const SInt16 kSoundGatePCM = 700;   // -33 dBFS：人声门限，环境底噪/空调声过不去

// 打开一个新的 .wav.part 开始正式录；withPreroll=YES 时把触发前的 2 秒预录补进去
static void CRWavOpenPart(CaptureChannel *ch, BOOL withPreroll) {
    if (!ch || !ch->wavDir[0]) return;
    char cur[768];
    snprintf(cur, sizeof(cur), "%s/%s_p%03d.wav.part", ch->wavDir, ch->wavStem, ch->wavPart);
    FILE *f = fopen(cur, "wb");
    if (!f) { CRAppLog(@"[录音] 无法创建 %s", cur); return; }
    CRWavHeader(f, ch->wavRate, 1);
    ch->wav = f;
    // 触发前的预录数据先刷进去，保证"开口第一句"完整
    if (withPreroll && ch->preroll && ch->prerollCount > 0) {
        UInt32 total = ch->prerollCount;
        UInt32 start = (ch->prerollPos + ch->prerollCap - total) % ch->prerollCap;
        if (start + total <= ch->prerollCap) {
            fwrite(ch->preroll + start, sizeof(SInt16), total, f);
        } else {
            UInt32 first = ch->prerollCap - start;
            fwrite(ch->preroll + start, sizeof(SInt16), first, f);
            fwrite(ch->preroll, sizeof(SInt16), total - first, f);
        }
        ch->wavFrames = total;
    }
    ch->prerollCount = 0;
    ch->prerollPos = 0;
    ch->wavSilentFrames = 0;
    ch->wavHadSound = YES;   // 已经确认有人声，停止时这段必须保留
    CRAppLog(@"[录音] ▶ 检测到人声 → 开始第%d段（含2秒预录，队列不重启）", ch->wavPart);
}

// 有声音就落盘，没声音就把样本塞进内存环形缓冲。
// v9.6 ★注意：判定"是否在说话"不能看单个采样 ——— 人声波形在零点上下振荡，
// 一个 1 kHz 的话音在每个过零点附近都低于门限。必须按「时间块」统计：
// 一个 0.1 秒的块里有 ≥30% 的采样超过门限，才算这块"有声"，
// 连续 6 个这样的块（≈0.6 秒）才认定真的在说话。
static void CRWavFeed(CaptureChannel *ch, SInt16 pcm, BOOL loud) {
    if (ch->wavLazy && !ch->wav) {
        // ===== 待机：只维护 2 秒预录环形缓冲 + 人声检测，磁盘上什么都没建 =====
        if (ch->preroll) {
            ch->preroll[ch->prerollPos] = pcm;
            ch->prerollPos = (ch->prerollPos + 1) % ch->prerollCap;
            if (ch->prerollCount < ch->prerollCap) ch->prerollCount++;
        }
        // 按 0.1 秒分块统计有声比例
        ch->gateBlockN++;
        if (loud) ch->gateLoudN++;
        if (ch->gateBlockN >= (UInt32)(0.1 * ch->wavRate)) {
            BOOL blockLoud = (ch->gateLoudN * 10 >= ch->gateBlockN * 3);   // ≥30%
            ch->gateBlockN = 0; ch->gateLoudN = 0;
            if (blockLoud) {
                ch->soundRun++;
                // 连续 6 个有声块 ≈ 0.6 秒：排除咳嗽、关门、桌面碰撞等瞬时噪声
                if (ch->soundRun >= 6) {
                    CRWavOpenPart(ch, YES);
                }
            } else {
                ch->soundRun = 0;
            }
        }
        return;
    }
    if (!ch->wav) return;
    ch->wavScratch[ch->wavOutN++] = pcm;
    if (loud) { ch->wavHadSound = YES; ch->wavSilentFrames = 0; }
    else ch->wavSilentFrames++;
}

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
        if (a > ch->uiPeak) ch->uiPeak = a;
        if (a > ch->peakEver) ch->peakEver = a;
        ch->sumSq += (double)s[i] * s[i];
        ch->sampleCount++;
    }
    // v9.2 ★决定性：同一份 PCM 直接写标准 WAV（Float32→Int16 整数抽取），
    // 不经过 AAC 编码器、不经过 CAF、不经过二次打开。回调有数据 → 文件里就必然有波形。
    // v9.6：待机（wavLazy 且 ch->wav 为 NULL）时也必须进这个分支 —— 
    // 正是这里在维护预录缓冲并检测人声，检测到才建文件。
    if ((ch->wav || ch->wavLazy) && ch->format.mBytesPerFrame > 0) {
        UInt32 inCh = ch->format.mChannelsPerFrame ? ch->format.mChannelsPerFrame : 1;
        UInt32 frames = buffer->mAudioDataByteSize / ch->format.mBytesPerFrame;
        // 待机时没有 scratch 容量上限的概念（只进 preroll），所以要放开上限
        UInt32 cap = ch->wavScratchCap ? ch->wavScratchCap : frames + 16;
        for (UInt32 i = 0; i < frames && ch->wavOutN < cap; i++) {
            double v = 0;
            for (UInt32 c = 0; c < inCh; c++) v += s[i * inCh + c];
            v /= inCh;                       // 立体声先合成为单声道
            ch->wavAcc += v; ch->wavAccN++;  // 累加平均 = 简易低通 + 整数抽取
            if (ch->wavAccN >= ch->wavDown) {
                double avg = ch->wavAcc / ch->wavAccN;
                ch->wavAcc = 0; ch->wavAccN = 0;
                if (avg > 1.0) avg = 1.0; else if (avg < -1.0) avg = -1.0;
                SInt16 pcm = (SInt16)(avg * 32767.0);
                if (pcm != 0) ch->wavNonZero++;
                // v9.6：没人说话就只进内存环形缓冲，一句人声都没检测到 → 根本不建文件
                CRWavFeed(ch, pcm, (pcm > kSoundGatePCM || pcm < -kSoundGatePCM));
            }
        }
        UInt32 outN = ch->wavOutN;
        ch->wavOutN = 0;
        if (outN > 0 && ch->wav) {
            fwrite(ch->wavScratch, sizeof(SInt16), outN, ch->wav);
            ch->wavFrames += outN;
        }
        CRWavRollIfNeeded(ch);   // v9.6：满60秒 / 说完静音15秒 → 封存；没说话就不建文件
    }
    ch->totalBytes += buffer->mAudioDataByteSize;
    ch->callbacks++;
    // v9.3 诊断：前 3 次 + 每 200 次打印，一眼看出队列是否持续跑、buffer 是否为空
    if (ch->callbacks <= 3 || ch->callbacks % 200 == 0) {
        CRAppLog(@"[回调] pid=%d #%d byteSize=%u 累计=%lluB 峰值=%.4f",
                 ch->pid, ch->callbacks, (unsigned)buffer->mAudioDataByteSize,
                 ch->totalBytes, ch->peakEver);
    }
    // ★v9.3 根因修复：旧代码用 if(ch->running) 决定是否重新入队，而 running 在
    // AudioQueueStart 之后才置 YES —— 前 3 个 buffer 的回调触发时 running=NO，
    // 于是 3 个预分配 buffer 用完就永久饿死（真机日志 mic回调=3 采样字节=0）。
    // 改为只有 stopChannel 显式置 stopRequested 才停止入队。
    if (!ch->stopRequested) AudioQueueEnqueueBuffer(aq, buffer, 0, NULL);
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
    // ★v9.3：必须在 Start 之前置位（回调可能同步触发），且回调已改为无条件入队
    ch->stopRequested = NO;
    ch->running = YES;
    st = AudioQueueStart(ch->queue, NULL);
    CRLog(@"pid=%d AudioQueueStart=%d buf=%u", pid, (int)st, (unsigned)ch->bufferSize);
    if (st != noErr) { ch->running = NO; return nil; }
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
- (BOOL)attachWavOutput:(NSURL *)url toChannel:(CaptureChannel *)ch down:(UInt32)down rollFrames:(UInt64)rollFrames {
    if (!url || !ch || down < 1) return NO;
    UInt32 rate = (UInt32)(kTapSampleRate / down);
    BOOL rolling = (rollFrames > 0);
    NSString *stem = [url.lastPathComponent stringByDeletingPathExtension];
    NSString *dirPath = [url URLByDeletingLastPathComponent].path;

    ch->wavDown = down;
    ch->wavRate = rate;
    ch->wavScratchCap = ch->bufferSize / (ch->format.mBytesPerFrame ?: 4) + 16;
    ch->wavScratch = (SInt16 *)calloc(ch->wavScratchCap, sizeof(SInt16));
    if (!ch->wavScratch) { CRAppLog(@"[WAV] 缓冲分配失败"); return NO; }
    ch->wavFrames = 0; ch->wavNonZero = 0; ch->wavAcc = 0; ch->wavAccN = 0;
    ch->wavSilentFrames = 0; ch->wavHadSound = NO;
    ch->wavOutN = 0; ch->soundRun = 0; ch->gateBlockN = 0; ch->gateLoudN = 0;

    if (rolling) {
        // ===== v9.6 常驻模式：延迟建文件，没检测到人声就一个文件都不生成 =====
        snprintf(ch->wavDir, sizeof(ch->wavDir), "%s", dirPath.fileSystemRepresentation);
        snprintf(ch->wavStem, sizeof(ch->wavStem), "%s", stem.UTF8String);
        ch->wavPart = 1;
        ch->wavRollFrames = rollFrames;
        ch->wavRolling = YES;
        ch->wavLazy = YES;
        ch->wav = NULL;
        // 2 秒预录环形缓冲：检测到人声时把这段先补进去，开口第一句不丢
        ch->prerollCap = (UInt32)(2.0 * rate);
        if (ch->prerollCap < 1024) ch->prerollCap = 1024;
        ch->preroll = (SInt16 *)calloc(ch->prerollCap, sizeof(SInt16));
        ch->prerollCount = 0; ch->prerollPos = 0;
        CRAppLog(@"[WAV] 常驻待机：不建文件，只在内存留2秒预录；检测到人声才落盘 → %@_pNNN.wav", stem);
    } else {
        // ===== 手动单点录音：立即建文件（用户已明确按下按钮，就是要录） =====
        NSString *actual = url.path;
        [[NSFileManager defaultManager] removeItemAtPath:actual error:nil];
        FILE *f = fopen(actual.fileSystemRepresentation, "wb");
        if (!f) { CRAppLog(@"[WAV] 打开失败 %@", actual.lastPathComponent); return NO; }
        CRWavHeader(f, rate, 1);
        ch->wav = f;
        ch->wavRolling = NO; ch->wavRollFrames = 0; ch->wavPart = 0;
        ch->wavLazy = NO;
        CRAppLog(@"[WAV] 已挂接 %.0f→%uHz/%u ÷%u → %@",
                 kTapSampleRate, (unsigned)rate, (unsigned)ch->format.mChannelsPerFrame,
                 (unsigned)down, actual.lastPathComponent);
    }
    return YES;
}

// v9.3 ★「单点开始录音」专用：标准麦克风 AudioQueue，完全不依赖私有 tap。
// 激活 AVAudioSession 后由系统直接推送麦克风 PCM —— 只要授权过就 100% 有数据，
// 用来把「输出文件为空」和「tap 抓不到对方声音」这两件事彻底分开。
- (CaptureChannel *)startPlainMicWithWavURL:(NSURL *)wavURL down:(UInt32)down error:(NSError **)error {
    CaptureChannel *ch = [CaptureChannel new];
    ch->pid = -3;
    AVAudioFormat *af = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                         sampleRate:kTapSampleRate
                                                           channels:1 interleaved:YES];
    ch->format = *([af streamDescription]);

    AVAudioSession *sess = [AVAudioSession sharedInstance];
    [sess setCategory:AVAudioSessionCategoryPlayAndRecord
                 mode:AVAudioSessionModeMeasurement
              options:AVAudioSessionCategoryOptionDefaultToSpeaker error:nil];
    [sess setActive:YES error:nil];

    // flag 0 = 普通输入队列；不建 tap、不设 qtob
    OSStatus st = AudioQueueNewInput(&ch->format, RecorderCallback, (__bridge void *)ch,
                                     NULL, NULL, 0, &ch->queue);
    if (st != noErr) {
        CRAppLog(@"[手动] AudioQueueNewInput 失败 st=%d", (int)st);
        if (error) *error = [NSError errorWithDomain:@"RecorderEngine" code:(int)st
                             userInfo:@{NSLocalizedDescriptionKey:@"无法创建麦克风录音队列"}];
        return nil;
    }
    CalcBufSize(ch->queue, ch->format, &ch->bufferSize);
    for (int i = 0; i < kNumberOfBuffers; i++) {
        st = AudioQueueAllocateBuffer(ch->queue, ch->bufferSize, &ch->buffers[i]);
        if (st != noErr) return nil;
        AudioQueueEnqueueBuffer(ch->queue, ch->buffers[i], 0, NULL);
    }
    ch->audioFile = 0;
    ch->currentPacket = 0;
    // WAV 在 Start 之前挂好，避免丢开头几个 buffer
    if (![self attachWavOutput:wavURL toChannel:ch down:down rollFrames:0]) {
        if (error) *error = [NSError errorWithDomain:@"RecorderEngine" code:-5
                             userInfo:@{NSLocalizedDescriptionKey:@"无法创建 WAV 文件"}];
        return nil;
    }
    ch->stopRequested = NO;
    ch->running = YES;                 // ★Start 之前
    st = AudioQueueStart(ch->queue, NULL);
    CRAppLog(@"[手动] 标准麦克风队列 Start=%d buf=%u (无tap/无qtob)", (int)st, (unsigned)ch->bufferSize);
    if (st != noErr) { ch->running = NO; return nil; }
    return ch;
}

// v9.4 ★自动模式主路：与「单点开始录音」完全同一套标准麦克风队列
// （真机已验证 100% 出声），差别只在会话选项：MixWithOthers + 不强制外放，
// 避免打断/改变微信、QQ 通话本身的音频路由。
// 私有 tap 在本机多版验证均为「回调有触发但 buffer 全 0 字节」（不推流），
// 不再把它当主路；app/sys 两路降级为「对方声道增强」，有数据才合成 _双方.wav。
- (CaptureChannel *)startAutoMicWithWavURL:(NSURL *)wavURL down:(UInt32)down error:(NSError **)error {
    CaptureChannel *ch = [CaptureChannel new];
    ch->pid = -3;
    AVAudioFormat *af = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                         sampleRate:kTapSampleRate
                                                           channels:1 interleaved:YES];
    ch->format = *([af streamDescription]);

    AVAudioSession *sess = [AVAudioSession sharedInstance];
    [sess setCategory:AVAudioSessionCategoryPlayAndRecord
                 mode:AVAudioSessionModeMeasurement
              options:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [sess setActive:YES error:nil];

    // flag 0 = 普通输入队列；不建 tap、不设 qtob —— 与已验证成功的单点路径一致
    OSStatus st = AudioQueueNewInput(&ch->format, RecorderCallback, (__bridge void *)ch,
                                     NULL, NULL, 0, &ch->queue);
    if (st != noErr) {
        CRAppLog(@"[自动] 标准麦克风 AudioQueueNewInput 失败 st=%d", (int)st);
        if (error) *error = [NSError errorWithDomain:@"RecorderEngine" code:(int)st
                             userInfo:@{NSLocalizedDescriptionKey:@"无法创建麦克风录音队列"}];
        return nil;
    }
    CalcBufSize(ch->queue, ch->format, &ch->bufferSize);
    for (int i = 0; i < kNumberOfBuffers; i++) {
        st = AudioQueueAllocateBuffer(ch->queue, ch->bufferSize, &ch->buffers[i]);
        if (st != noErr) return nil;
        AudioQueueEnqueueBuffer(ch->queue, ch->buffers[i], 0, NULL);
    }
    ch->audioFile = 0;
    ch->currentPacket = 0;
    // WAV 在 Start 之前挂好；★v9.6 常驻模式只是登记"待机"，不立即建文件
    UInt64 rollFrames = (UInt64)(60.0 * kTapSampleRate / down);
    if (![self attachWavOutput:wavURL toChannel:ch down:down rollFrames:rollFrames]) {
        if (error) *error = [NSError errorWithDomain:@"RecorderEngine" code:-5
                             userInfo:@{NSLocalizedDescriptionKey:@"无法创建 WAV 文件"}];
        return nil;
    }
    ch->stopRequested = NO;
    ch->running = YES;                 // ★Start 之前，配合 v9.3 的无条件重新入队
    st = AudioQueueStart(ch->queue, NULL);
    CRAppLog(@"[自动] 标准麦克风主路 Start=%d buf=%u (MixWithOthers, 不强制外放)",
             (int)st, (unsigned)ch->bufferSize);
    if (st != noErr) { ch->running = NO; return nil; }
    return ch;
}

// v9.5 ★常驻录音入口：整个生命周期只启动一次，队列与 AVAudioSession 全程不重启。
// 每 60 秒的文件切换发生在采集回调内部（只换 FILE*），不再 stop/start 引擎。
// 不建 app-tap 增强路 —— 本机该路多版验证恒不推流，重建它只会增加卡死风险。
- (BOOL)startContinuousWithFileURL:(NSURL *)fileURL error:(NSError **)error {
    if (_recording) return YES;
    if (_monitoring) [self stopMonitoring];
    _autoMode = YES;
    _appTapActive = NO;
    _outURL = fileURL;
    _micURL = nil; _spkURL = nil; _appURL = nil; _sysURL = nil;
    _appWavURL = nil; _sysWavURL = nil;
    UInt32 down = (_quality == TRQualityHigh) ? 1 : ((_quality == TRQualityNormal) ? 2 : 4);
    _mic = [self startAutoMicWithWavURL:fileURL down:down error:error];
    if (!_mic) { [self fail:@"常驻麦克风启动失败" error:error]; return NO; }
    _recording = YES;
    CRAppLog(@"[常驻] v9.6 启动OK | 待机不建文件, 检测到人声才落盘; 说完静音15秒封存; 基础名=%@",
             fileURL.lastPathComponent);
    return YES;
}

- (NSInteger)callbackCount { return _mic ? _mic->callbacks : 0; }

// v9.6 界面同步：让界面能读到常驻录音的实时进度。
// 旧版界面只在「手动点按钮成功」时才会把按钮改成"停止录音"并启动电平定时器，
// 而常驻录音是 AppCallMonitor 自己启的，界面完全不知道 → 用户看到"有文件但按钮没动"。
- (NSInteger)currentSegmentIndex {
    if (!_mic || !_mic->wavRolling) return 0;
    return _mic->wav ? _mic->wavPart : 0;   // 0 = 待机中（还没检测到人声，没建文件）
}
- (double)currentSegmentSeconds {
    if (!_mic || _mic->wavRate == 0 || !_mic->wav) return 0;
    return (double)_mic->wavFrames / (double)_mic->wavRate;
}
- (NSInteger)sealedSegmentCount {
    if (!_mic || !_mic->wavRolling) return 0;
    return _mic->wavPart - 1;
}

// v9.6 界面电平：取「界面专用峰值」后衰减一半。
// 不能直接用 micLevel —— 那个 peak 被看门狗每 5 秒 consumeAutoLevelsMic 清零，
// 界面 0.5 秒读一次会读到大量 0，表现为电平条忽亮忽灭、看着像没在录。
- (float)uiMicLevel {
    if (!_mic) return 0;
    float v = _mic->uiPeak;
    _mic->uiPeak = v * 0.5f;    // 每 tick 衰减，形成自然的电平条回弹
    return v;
}

// v9：官方免费版配方 —— 按微信/QQ 真实进程 PID 做 app-tap（v9.5 起不再调用，保留兼容）
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

    // ★v9.4 自己：标准麦克风主路（真机「单点」已验证 100% 出声）。
    // 不再用私有 tap 的 -3 —— 本机 tap 回调 buffer 恒为 0 字节，是自动模式零文件的根因。
    _mic = [self startAutoMicWithWavURL:_outURL down:down error:error];
    if (!_mic) { [self fail:@"标准麦克风主路启动失败" error:error]; return NO; }
    CRAppLog(@"[WAV] 主路=标准麦克风队列(确定有数据) → %@", _outURL.lastPathComponent);

    // 对方：真实进程 PID app-tap（★v9.4 降级为增强路，仅用于合成 _双方.wav；
    // 这台设备上 tap 不推流，失败也完全不影响标准麦克风主文件）
    if (appPIDs.count > 0) {
        _app = [self startChannelWithPIDs:appPIDs channels:2 fileURL:nil
                                 labelPid:appPIDs.firstObject.intValue error:nil];
        if (_app) {
            _appTapActive = YES;
            [self attachWavOutput:_appWavURL toChannel:_app down:down rollFrames:0];
            CRLog(@"★app-tap 真实PID 启动成功: %@", appPIDs);
        }
    }
    if (!_app) {
        CRLog(@"app-tap 不可用 → 回退 -2 系统混音");
        _app = [self startChannelWithPID:kATAudioTapDescriptionPIDSpeaker channels:2 fileURL:nil error:nil];
        if (_app) [self attachWavOutput:_appWavURL toChannel:_app down:down rollFrames:0];
    }

    // 诊断/兜底：-2 系统混音。仅当 app-tap 成功时再开（避免同 PID 双队列）
    if (_appTapActive) {
        _sys = [self startChannelWithPID:kATAudioTapDescriptionPIDSpeaker channels:2 fileURL:nil error:nil];
        if (_sys) [self attachWavOutput:_sysWavURL toChannel:_sys down:down rollFrames:0];
    } else {
        _sys = nil;
    }

    _recording = YES;
    CRAppLog(@"[自动] v9.4 通道: 主路标准麦克风=%@ | 增强路 app-tap=%@ sys混音=%@ (增强路无数据不影响出文件)",
             _mic?@"OK":@"FAIL", _app?@"OK":@"N/A", _sys?@"OK":@"N/A");
    return _mic != nil;
}

- (BOOL)startWithChannel:(TRChannel)channel fileURL:(NSURL *)fileURL error:(NSError **)error {
    if (_recording) return YES;
    if (_monitoring) [self stopMonitoring];
    _autoMode = NO;
    _channel = channel;
    _outURL = fileURL;
    // v9.3：手动「单点开始录音」改走标准麦克风队列，不再依赖私有 tap。
    // 之前手动/自动共用 tap 通道，一旦 tap 不推数据 / 队列饿死，就必然「输出文件为空」。
    UInt32 down = (_quality == TRQualityHigh) ? 1 : ((_quality == TRQualityNormal) ? 2 : 4);
    self->_micURL = nil; self->_spkURL = nil; self->_appURL = nil; self->_sysURL = nil;
    CRLog(@"========== 开始录音 v9.4 (标准麦克风 WAV) iOS=%@ ==========", [UIDevice currentDevice].systemVersion);
    _mic = [self startPlainMicWithWavURL:_outURL down:down error:error];
    if (!_mic) { [self fail:@"麦克风启动失败" error:error]; return NO; }
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
    (void)fm; (void)MixCAFs; (void)SampleRateForQuality;   // 旧链路保留但不再调用，避免未使用告警

    // ============ v9.5 自动常驻模式：只做收尾，不做任何混音/择优 ============
    if (_autoMode) {
        // 只有「用户关闭自动开关 / App 退出」才会走到这里，整段运行期间会话一直 active
        [[AVAudioSession sharedInstance] setActive:NO error:nil];
        CRAppLog(@"[停止] 常驻录音结束 | 回调=%d 累计字节=%llu 峰值Ever=%.4f | 已封存%d段WAV | 待机时长内未产生文件是正常的",
                 _mic ? _mic->callbacks : 0, _mic ? _mic->totalBytes : 0,
                 _mic ? _mic->peakEver : 0, _mic ? (_mic->wavPart - 1) : 0);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"CallRecorderSegmentRolled" object:nil];
        });
        [self cleanup];
        return;
    }

    // ============ v9.3 手动模式：标准麦克风已直接写 WAV，只需收尾 ============
    UInt64 mFrames  = _mic ? _mic->wavFrames   : 0;
    UInt64 mNonZero = _mic ? _mic->wavNonZero  : 0;
    UInt64 mBytes   = CRFileSize(_outURL);
    CRAppLog(@"[停止] 手动 WAV: 回调=%d 帧=%llu 非零=%llu 字节=%llu",
             _mic ? _mic->callbacks : 0, mFrames, mNonZero, mBytes);
    [[AVAudioSession sharedInstance] setActive:NO error:nil];
    if (mBytes > 44 && mNonZero > 0) {
        CRLog(@"录音完成(手动WAV)：%@ (%lluB)", _outURL.lastPathComponent, mBytes);
        if ([_delegate respondsToSelector:@selector(recorderDidFinishWithURL:micLevel:speakerLevel:)])
            [_delegate recorderDidFinishWithURL:_outURL micLevel:_mic ? _mic->peakEver : 0 speakerLevel:0];
    } else {
        CRAppLog(@"[停止] 手动录音没采到声音（队列回调=%d）", _mic ? _mic->callbacks : 0);
        if ([_delegate respondsToSelector:@selector(recorderDidFailWithMessage:)])
            [_delegate recorderDidFailWithMessage:@"麦克风没采到数据，请检查系统设置里是否允许本 App 使用麦克风"];
    }
    [self cleanup];
}

- (void)stopChannel:(CaptureChannel *)ch {
    if (!ch) return;
    ch->stopRequested = YES;   // v9.3: 让回调不再重新入队
    ch->running = NO;
    if (ch->queue) { AudioQueueStop(ch->queue, true); AudioQueueRemovePropertyListener(ch->queue, kAudioQueueProperty_IsRunning, ListenerCallback, (__bridge void *)ch); }
    if (ch->audioFile) { AudioFileClose(ch->audioFile); ch->audioFile = 0; }
    if (ch->extFile) { ExtAudioFileDispose(ch->extFile); ch->extFile = NULL; }
    if (ch->queue) { AudioQueueDispose(ch->queue, true); ch->queue = NULL; }
    // v9.2：所有回调都结束后，回填 WAV 头长度并关闭
    // v9.5：滚动模式下把正在写的 .part 封存成可直接播放的 .wav
    // v9.6：懒建文件模式下 ch->wav 可能为 NULL（全程没人说话），此时什么都不用做
    if (ch->wav) {
        CRWavFinalize(ch->wav, ch->wavFrames, 1); fclose(ch->wav); ch->wav = NULL;
        if (ch->wavRolling) {
            char cur[768], fin[768];
            snprintf(cur, sizeof(cur), "%s/%s_p%03d.wav.part", ch->wavDir, ch->wavStem, ch->wavPart);
            snprintf(fin, sizeof(fin), "%s/%s_p%03d.wav", ch->wavDir, ch->wavStem, ch->wavPart);
            if (ch->wavHadSound) rename(cur, fin);
            else remove(cur);
        }
    }
    if (ch->wavScratch) { free(ch->wavScratch); ch->wavScratch = NULL; }
    if (ch->preroll) { free(ch->preroll); ch->preroll = NULL; }
    ch->prerollCount = 0; ch->prerollPos = 0; ch->prerollCap = 0;
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
