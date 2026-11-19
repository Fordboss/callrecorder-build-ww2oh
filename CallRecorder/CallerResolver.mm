#import "CallerResolver.h"
#import <Contacts/Contacts.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <sys/types.h>

// ============================================================
// v9.11 通话对方识别
// ------------------------------------------------------------
// ★ 这个文件不碰任何音频代码。它只在主线程被定时器调用，返回一个字符串。
//   如果它整个失效（私有 API 变了、用户拒了通讯录），录音仍按原样工作，
//   只是文件名退回纯时间戳 —— 这是硬约束，写在代码里。
//
// 为什么不直接 import TelephonyUtilities 头：
//   1. 链接私有框架会让二进制多一条 @rpath 依赖，框架/方法不存在时启动即崩；
//   2. 这里改用 dlopen + 声明「代理接口」的方式：
//      只把 id 指针转成我们声明的方法集再调用，不引用对方的类符号，
//      私有 API 改名/消失时只是 respondsToSelector 失败 → 优雅降级。
// ============================================================

#pragma mark - 私有 API 的「代理声明」（仅用于调用，不实现）

// 方法集与官方 TRCallMonitor 一致：TUCallCenter / TUCall / TUHandle
@interface CRProxyTUCallCenter : NSObject
+ (instancetype)sharedInstance;
- (id)currentCall;          // 正在进行的通话
- (id)displayedCall;        // 界面上显示的通话（部分版本比 currentCall 更早可用）
- (NSArray *)calls;
- (NSArray *)displayedCalls;
@end

@interface CRProxyTUCall : NSObject
- (id)handle;
- (id)remoteHandle;
- (BOOL)isConnected;
- (BOOL)isEnded;
- (BOOL)isOutgoing;
- (NSString *)displayName;
- (NSString *)contactIdentifier;
@end

@interface CRProxyTUHandle : NSObject
- (NSString *)value;
- (NSInteger)type;          // 2=电话 3=email
@end

#pragma mark - 工具

// 进程扫描：判断微信/QQ 主进程是否在跑。
// 拿不到就返回 nil —— 调用方当作「没有第三方通话」处理。
static NSString *CRRunningCallApp(void) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) return nil;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return nil;
    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) { free(procs); return nil; }

    NSString *found = nil;
    int n = (int)(size / sizeof(struct kinfo_proc));
    for (int i = 0; i < n; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        const char *comm = procs[i].kp_proc.p_comm;
        if (pid <= 0 || !comm) continue;
        NSString *low = ([NSString stringWithUTF8String:comm] ?: @"").lowercaseString;
        // 扩展/Widget/分享进程不算「在通话」
        BOOL helper = [low containsString:@"notific"] || [low containsString:@"widget"]
                   || [low containsString:@"extension"] || [low containsString:@"share"];
        if (helper) continue;
        if ([low hasPrefix:@"wechat"]) { found = @"微信通话"; break; }
        if ([low hasPrefix:@"mobileqq"] || [low hasPrefix:@"qq"]) {
            if (!found) found = @"QQ通话";
        }
    }
    free(procs);
    return found;
}

// 号码归一化：只留数字（+86 / 空格 / 横线统统去掉）
static NSString *CRDigitsOnly(NSString *s) {
    if (!s) return nil;
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= '0' && c <= '9') [out appendFormat:@"%C", c];
    }
    return out.length ? out : nil;
}

// 号码比对：+8613800138000 / 13800138000 / 010-12345678 vs 01012345678 视为同一个
static BOOL CRPhoneEqual(NSString *a, NSString *b) {
    NSString *x = CRDigitsOnly(a), *y = CRDigitsOnly(b);
    if (!x || !y) return NO;
    if ([x isEqualToString:y]) return YES;
    // 去掉国家码 86
    NSString *sx = x, *sy = y;
    if (sx.length > 11 && [sx hasPrefix:@"86"]) sx = [sx substringFromIndex:2];
    if (sy.length > 11 && [sy hasPrefix:@"86"]) sy = [sy substringFromIndex:2];
    if (sx.length >= 7 && [sx isEqualToString:sy]) return YES;
    // 座机去掉前导 0
    if (sx.length >= 7 && sy.length >= 7) {
        NSString *tx = [sx hasPrefix:@"0"] ? [sx substringFromIndex:1] : sx;
        NSString *ty = [sy hasPrefix:@"0"] ? [sy substringFromIndex:1] : sy;
        if ([tx isEqualToString:ty]) return YES;
    }
    return NO;
}

// 号码脱敏：13912345678 → 139****5678（不是联系人时用，避免文件名泄露完整号码）
static NSString *CRMaskPhone(NSString *phone) {
    NSString *d = CRDigitsOnly(phone);
    if (!d || d.length >= 11) {
        if (!d) return phone ?: nil;
        NSString *head = [d substringToIndex:3];
        NSString *tail = [d substringFromIndex:d.length - 4];
        return [NSString stringWithFormat:@"%@****%@", head, tail];
    }
    return phone;   // 短号/短座机原样
}

#pragma mark - 内部实现

@interface CRCallerResolverImpl : NSObject
@property (nonatomic, assign) void *tuHandle;
@property (nonatomic, assign) BOOL  tuTried;
@property (nonatomic, strong) CNContactStore *store;
@property (nonatomic, assign) BOOL  contactsDenied;
@property (nonatomic, copy)   NSString *diag;
@end

@implementation CRCallerResolverImpl

- (BOOL)loadTU {
    if (self.tuTried) return (self.tuHandle != NULL);
    self.tuTried = YES;
    const char *paths[] = {
        "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/TelephonyUtilities",
        "/System/Library/Frameworks/TelephonyUtilities.framework/TelephonyUtilities",
    };
    for (size_t i = 0; i < sizeof(paths)/sizeof(paths[0]); i++) {
        void *h = dlopen(paths[i], RTLD_LAZY | RTLD_LOCAL);
        if (h) { self.tuHandle = h; break; }
    }
    if (!self.tuHandle) self.diag = @"TU框架加载失败";
    return self.tuHandle != NULL;
}

// 取当前通话（依次尝试 currentCall → displayedCall → calls → displayedCalls）
- (id)activeCall {
    if (![self loadTU]) return nil;
    // ★用 id 接类对象：对 Class 直接发类方法，编译器要求能看见声明；
    //   id 是无类型消息接收者，配合 respondsToSelector 才既能编过又不依赖私有头。
    id cls = NSClassFromString(@"TUCallCenter");
    if (!cls) { self.diag = @"TUCallCenter 类不存在"; return nil; }

    id centerRaw = nil;
    if ([cls respondsToSelector:@selector(sharedInstance)]) {
        centerRaw = [cls sharedInstance];
    }
    if (!centerRaw) { self.diag = @"TUCallCenter 无实例"; return nil; }
    CRProxyTUCallCenter *center = (CRProxyTUCallCenter *)centerRaw;

    NSMutableArray *candidates = [NSMutableArray array];
    if ([center respondsToSelector:@selector(currentCall)]) {
        id c = [center currentCall]; if (c) [candidates addObject:c];
    }
    if ([center respondsToSelector:@selector(displayedCall)]) {
        id c = [center displayedCall]; if (c) [candidates addObject:c];
    }
    if ([center respondsToSelector:@selector(calls)]) {
        NSArray *a = [center calls]; if (a.count) [candidates addObjectsFromArray:a];
    }
    if ([center respondsToSelector:@selector(displayedCalls)]) {
        NSArray *a = [center displayedCalls]; if (a.count) [candidates addObjectsFromArray:a];
    }

    for (id raw in candidates) {
        CRProxyTUCall *c = (CRProxyTUCall *)raw;
        BOOL ended = [c respondsToSelector:@selector(isEnded)] ? [c isEnded] : NO;
        if (ended) continue;
        // 只认「已接通或正在响铃」的，已结束的跳过
        return c;
    }
    self.diag = candidates.count ? @"通话均已结束" : @"TU 无通话对象";
    return nil;
}

// 通讯录：identifier 直查（最快最准）
- (NSString *)nameForIdentifier:(NSString *)ident {
    if (self.contactsDenied || !ident.length) return nil;
    if (![self ensureContactsAccess]) return nil;
    NSError *err = nil;
    NSArray<id<CNKeyDescriptor>> *keys = @[ CNContactGivenNameKey, CNContactFamilyNameKey,
                                            CNContactNicknameKey, CNContactOrganizationNameKey ];
    CNContact *c = [self.store unifiedContactWithIdentifier:ident keysToFetch:keys error:&err];
    if (!c) return nil;
    NSString *nm = [NSString stringWithFormat:@"%@%@", c.familyName ?: @"", c.givenName ?: @""];
    if (!nm.length) nm = c.nickname ?: c.organizationName ?: @"";
    return nm.length ? nm : nil;
}

// 通讯录：按号码遍历匹配（identifier 拿不到时兜底）
- (NSString *)nameForPhone:(NSString *)phone {
    if (self.contactsDenied || !phone.length) return nil;
    if (![self ensureContactsAccess]) return nil;
    NSError *err = nil;
    NSArray<id<CNKeyDescriptor>> *keys = @[ CNContactGivenNameKey, CNContactFamilyNameKey,
                                            CNContactNicknameKey, CNContactOrganizationNameKey,
                                            CNContactPhoneNumbersKey ];
    CNContactFetchRequest *req = [[CNContactFetchRequest alloc] initWithKeysToFetch:keys];
    __block NSString *hit = nil;
    [self.store enumerateContactsWithFetchRequest:req error:&err
                                       usingBlock:^(CNContact *c, BOOL *stop) {
        for (CNLabeledValue<CNPhoneNumber *> *pn in c.phoneNumbers) {
            if (CRPhoneEqual(pn.value.stringValue, phone)) {
                NSString *nm = [NSString stringWithFormat:@"%@%@", c.familyName ?: @"", c.givenName ?: @""];
                if (!nm.length) nm = c.nickname ?: c.organizationName ?: @"";
                if (nm.length) { hit = nm; *stop = YES; }
                break;
            }
        }
    }];
    if (err) self.diag = [NSString stringWithFormat:@"通讯录读取失败:%@", err.localizedDescription];
    return hit;
}

// 权限检查（不主动弹窗：弹窗在 AppCallMonitor.start 里一次性发起）
- (BOOL)ensureContactsAccess {
    if (!self.store) self.store = [CNContactStore new];
    CNAuthorizationStatus st = [CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts];
    if (st == CNAuthorizationStatusAuthorized) return YES;
    if (st == CNAuthorizationStatusDenied || st == CNAuthorizationStatusRestricted) {
        self.contactsDenied = YES;
    }
    return NO;
}

@end

#pragma mark - 对外封装

@interface CallerResolver ()
@property (nonatomic, strong) CRCallerResolverImpl *impl;
@property (nonatomic, assign, readwrite) BOOL systemCallDetected;
@property (nonatomic, copy, readwrite) NSString *lastDiagnostic;
@end

@implementation CallerResolver

+ (instancetype)shared {
    static CallerResolver *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [CallerResolver new]; });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _impl = [CRCallerResolverImpl new];
    }
    return self;
}

// 文件名清洗：去掉路径分隔符、控制字符、冒号；压缩空白；限长。
+ (NSString *)sanitizeForFilename:(NSString *)raw maxLength:(NSUInteger)maxLen {
    if (!raw.length) return nil;
    NSMutableString *s = [NSMutableString stringWithCapacity:raw.length];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if (c < 0x20 || c == 0x7F) continue;                       // 控制字符
        if (c == '/' || c == '\\' || c == ':' || c == '*' ||
            c == '?' || c == '"' || c == '<' || c == '>' || c == '|') continue;
        [s appendFormat:@"%C", c];
    }
    NSString *out = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([out containsString:@"  "])
        out = [out stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    if (!out.length) return nil;
    if (maxLen > 0 && out.length > maxLen) out = [out substringToIndex:maxLen];
    return out;
}

- (NSString *)currentCallerName {
    self.systemCallDetected = NO;

    // ① 系统电话 / FaceTime：唯一能拿到真实姓名的情况
    @try {
        CRProxyTUCall *call = (CRProxyTUCall *)[self.impl activeCall];
        if (call) {
            self.systemCallDetected = YES;

            NSString *display = nil;
            if ([call respondsToSelector:@selector(displayName)]) display = [call displayName];

            NSString *ident = nil;
            if ([call respondsToSelector:@selector(contactIdentifier)]) ident = [call contactIdentifier];

            NSString *handle = nil;
            id h = nil;
            if ([call respondsToSelector:@selector(handle)]) h = [call handle];
            if (!h && [call respondsToSelector:@selector(remoteHandle)]) h = [call remoteHandle];
            if ([h respondsToSelector:@selector(value)]) handle = [(CRProxyTUHandle *)h value];

            // 姓名来源：identifier 查通讯录 > 号码查通讯录 > CNAP显示名 > 脱敏号码
            NSString *name = [self.impl nameForIdentifier:ident];
            if (!name.length && handle.length) name = [self.impl nameForPhone:handle];
            if (!name.length && display.length && ![display isEqualToString:handle]) name = display;
            if (!name.length && handle.length) name = CRMaskPhone(handle);

            self.lastDiagnostic = [NSString stringWithFormat:
                @"系统电话 handle=%@ ident=%@ 名字=%@",
                handle.length ? CRMaskPhone(handle) : @"nil",
                ident.length ? @"有" : @"无",
                name ?: @"nil"];

            NSString *clean = [CallerResolver sanitizeForFilename:name maxLength:40];
            if (clean.length) return clean;
            return nil;
        }
        self.lastDiagnostic = self.impl.diag ?: @"无系统通话";
    } @catch (NSException *e) {
        self.lastDiagnostic = [NSString stringWithFormat:@"TU异常:%@", e.reason ?: @"?"];
    }

    // ② 微信 / QQ：系统不告诉你「和谁通话」，只能标 App 名。
    //    注意：文件只在「检测到人声」时才创建，所以这个标记只会出现在真有声音的文件上。
    NSString *app = CRRunningCallApp();
    if (app) {
        self.lastDiagnostic = [NSString stringWithFormat:@"%@（未注入，取不到具体联系人）", app];
        return app;
    }

    self.lastDiagnostic = @"无通话";
    return nil;
}

@end
