#import <Foundation/Foundation.h>

// v9.11 通话对方识别（只用于「给录音文件起名」，绝不参与录音链路）
//
// 能力边界（务必先读）：
//   * 系统电话 / FaceTime：走私有框架 TelephonyUtilities 的 TUCallCenter 取当前通话，
//     再拿 handle.value（号码）或 contactIdentifier 去 CNContactStore 匹配通讯录 → 真名。
//     这条路径与官方 TrollRecorder 的 TRCallMonitor 同源（它同时链接了
//     TelephonyUtilities.framework 与 Contacts，符号含 PrimaryCall / ContactIdentifier / ContactName）。
//   * 微信 / QQ：不走 CallKit，也没有任何系统 API 能告诉你「正在和谁通话」。
//     官方是靠 Theos tweak 注入微信进程（MMServiceCenter / openAudioWindowWithContact:）
//     才能拿到 wxid / 备注。本 App 不注入，所以只能标成「微信通话」「QQ通话」，
//     拿不到具体是谁。这是系统边界，不是实现偷懒。
//
// 设计约束（防止再次拖垮录音）：
//   1. 所有查询都在主线程定时器里做，绝不进音频回调线程；
//   2. TelephonyUtilities 用 dlopen 动态加载 —— 链接期零风险，私有 API 不存在时只是降级；
//   3. 任何一步失败都返回 nil，调用方退回「纯时间戳」命名，录音本身不受影响。
@interface CallerResolver : NSObject

+ (instancetype)shared;

// 当前通话对方的名字。返回值已经过「文件名安全」清洗，可直接拼进文件名。
//   系统电话：通讯录姓名 > 号码（脱敏）> nil
//   微信/QQ ：@"微信通话" / @"QQ通话"
//   无通话   ：nil
- (NSString *)currentCallerName;

// 是否真的检测到系统电话（TUCallCenter 能取到未结束的 call）。
// 用于区分「真电话」和「只是微信在后台跑」。
@property (nonatomic, readonly) BOOL systemCallDetected;
// 最近一次解析过程的说明，写进诊断日志用（例如 "TU=nil" / "号码=+8613***" / "命中通讯录=张三"）
@property (nonatomic, readonly) NSString *lastDiagnostic;

// 把任意字符串清洗成可用于文件名的形式（去掉路径分隔符/控制字符，限长）
+ (NSString *)sanitizeForFilename:(NSString *)raw maxLength:(NSUInteger)maxLen;

@end
