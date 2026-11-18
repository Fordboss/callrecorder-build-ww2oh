#import "ManualControl.h"
#import "RecorderEngine.h"
#import <UserNotifications/UserNotifications.h>
#import <UIKit/UIKit.h>

NSString * const ManualRecordingDoneNotification = @"ManualRecordingDone";

static NSString * const kCategoryID = @"CallRecorderManualCtl";
static NSString * const kActRecord  = @"ACTION_RECORD";   // 开始/停止
static NSString * const kActStatus  = @"ACTION_STATUS";   // 查询状态

@implementation ManualControl

+ (instancetype)shared {
    static ManualControl *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (void)setup {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = (id<UNUserNotificationCenterDelegate>)[UIApplication sharedApplication].delegate;

    UNNotificationAction *record =
        [UNNotificationAction actionWithIdentifier:kActRecord
                                             title:@"● 开始 / ■ 停止录音"
                                           options:UNNotificationActionOptionForeground];
    UNNotificationCategory *cat =
        [UNNotificationCategory categoryWithIdentifier:kCategoryID
                                               actions:@[ record ]
                                     intentIdentifiers:@[]
                                               options:UNNotificationCategoryOptionNone];
    [center setNotificationCategories:[NSSet setWithObject:cat]];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(recordingDone:)
                                                 name:ManualRecordingDoneNotification
                                               object:nil];
}

- (void)requestPermissionAndEnable {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert |
                                             UNAuthorizationOptionSound |
                                             UNAuthorizationOptionBadge)
                          completionHandler:^(BOOL granted, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (granted) {
                [self postControlNotification];
            }
        });
    }];
}

// 常驻的手动控制通知：微信/QQ 通话时下拉通知中心点一下即可开始/停止
- (void)postControlNotification {
    BOOL recording = [RecorderEngine shared].isRecording;
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = recording ? @"🔴 通话录音进行中" : @"🎙 手动通话录音助手";
    content.body  = recording
        ? @"正在双路录音（自己+对方）。通话结束后点此保存。"
        : @"微信/QQ 来电后，点此按钮开始录音；再点一次停止保存。无需切回 App。";
    content.categoryIdentifier = kCategoryID;
    content.sound = recording ? nil : [UNNotificationSound defaultSound];
    // 不设 trigger：立即投递。identifier 固定 → 重复投递会覆盖旧的，始终只有一条
    UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:kCategoryID
                                                                     content:content
                                                                     trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:req
                                                           withCompletionHandler:^(NSError * _Nullable error) {
        if (error) NSLog(@"[Manual] 投递通知失败: %@", error);
    }];
}

- (void)handleAction:(NSString *)identifier {
    if ([identifier isEqualToString:kActRecord]) {
        RecorderEngine *engine = [RecorderEngine shared];
        if (engine.isRecording) {
            [engine stop];
        } else {
            [self startRecording];
        }
        // 刷新控制通知状态（短暂延迟，等引擎状态更新）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self postControlNotification];
        });
    }
}

- (void)startRecording {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *name = [NSString stringWithFormat:@"manual_%@.m4a", [fmt stringFromDate:[NSDate date]]];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSURL *url = [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:name]];

    NSError *error = nil;
    BOOL ok = [[RecorderEngine shared] startWithChannel:TRChannelSystemAudio fileURL:url error:&error];
    NSLog(@"[Manual] 通知触发录音 %@ %@", ok ? @"成功" : @"失败", error.localizedDescription ?: @"");
}

- (void)recordingDone:(NSNotification *)n {
    // 录音完成 → 推一条结果通知，用户在微信里也能看到电平判断有没有录到
    NSString *body = n.userInfo[@"body"] ?: @"录音已保存";
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = @"✅ 录音已保存";
    content.body = body;
    content.sound = [UNNotificationSound defaultSound];
    UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:@"CallRecorderResult"
                                                                     content:content
                                                                     trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:req
                                                           withCompletionHandler:nil];
    // 完成后把控制条恢复成"未录音"状态
    [self postControlNotification];
}

@end
