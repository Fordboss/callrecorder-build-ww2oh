#import "ViewController.h"
#import "RecorderEngine.h"
#import "CallMonitor.h"
#import "ManualControl.h"
#import "FloatingBall.h"
#import "DarwinMonitor.h"
#import "AppCallMonitor.h"
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

@interface ViewController () <AVAudioPlayerDelegate, UITableViewDelegate, UITableViewDataSource,
                              SFSpeechRecognizerDelegate, RecorderEngineDelegate>

@property (nonatomic, strong) UISegmentedControl *channelPicker;
@property (nonatomic, strong) UIButton   *recordButton;
@property (nonatomic, strong) UIButton   *qualityButton;
@property (nonatomic, strong) UISwitch  *autoSwitch;
@property (nonatomic, strong) UIButton   *notifyBtn;      // 启用通知栏手动控制
@property (nonatomic, strong) UISwitch  *floatSwitch;     // 悬浮球开关
@property (nonatomic, strong) UISwitch  *wxSwitch;        // 微信通话自动录音开关
@property (nonatomic, strong) UILabel    *statusLabel;
@property (nonatomic, strong) UILabel    *levelLabel;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSURL *> *files;
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, assign) NSInteger playingIndex;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL autoRecording;   // 本次录音是否由来电自动触发

@property (nonatomic, strong) SFSpeechRecognizer *speechRecognizer;
@property (nonatomic, strong) SFSpeechRecognitionTask *speechTask;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"通话录音机 Pro";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.playingIndex = -1;

    [RecorderEngine shared].delegate = self;
    [self setupNavBar];
    [self setupUI];
    [self loadFiles];

    self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"zh-CN"]];
    self.speechRecognizer.delegate = self;
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {}];

    // 来电自动录音事件
    __weak typeof(self) wf = self;
    [CallMonitor shared].onCallStateChange = ^(NSString *state) {
        dispatch_async(dispatch_get_main_queue(), ^{
            wf.statusLabel.text = [NSString stringWithFormat:@"📞 %@", state];
        });
    };
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(autoStart)
                                                 name:@"CallRecorderAutoStart" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(autoStop)
                                                 name:@"CallRecorderAutoStop" object:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

#pragma mark - 导航栏

- (void)setupNavBar {
    UIBarButtonItem *wxLog = [[UIBarButtonItem alloc] initWithTitle:@"微信日志"
                                                             style:UIBarButtonItemStylePlain
                                                            target:self action:@selector(shareWeChatLog)];
    UIBarButtonItem *recLog = [[UIBarButtonItem alloc] initWithTitle:@"录音日志"
                                                              style:UIBarButtonItemStylePlain
                                                             target:self action:@selector(shareDebugLog)];
    self.navigationItem.rightBarButtonItems = @[ recLog, wxLog ];
}
- (void)shareWeChatLog {
    // 免注入检测日志为主（appcall_monitor.log），旧的注入日志为辅
    NSURL *newURL = [AppCallMonitor shared].logURL;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSURL *oldURL = [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:@"wechat_auto.log"]];
    NSString *newText = [[AppCallMonitor shared] recentLog:120];
    if (newText.length == 0 && ![[NSFileManager defaultManager] fileExistsAtPath:oldURL.path]) {
        [self alert:@"还没有日志。保持本 App 在后台，打一通微信/QQ电话后回来看。" title:@"自动录音诊断日志"]; return;
    }
    NSMutableArray *items = [NSMutableArray array];
    if (newText.length) [items addObject:newText];
    if ([[NSFileManager defaultManager] fileExistsAtPath:oldURL.path]) [items addObject:oldURL];
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    av.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:av animated:YES completion:nil];
}
- (void)shareDebugLog {
    NSURL *url = [[RecorderEngine shared] debugLogURL];
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        [self alert:@"还没有日志，先录一次音再导出。" title:@"诊断日志"]; return;
    }
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    av.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:av animated:YES completion:nil];
}

#pragma mark - UI

- (void)setupUI {
    UISegmentedControl *picker = [[UISegmentedControl alloc] initWithItems:@[@"双方(推荐)", @"仅麦克风", @"仅扬声器"]];
    picker.translatesAutoresizingMaskIntoConstraints = NO;
    picker.selectedSegmentIndex = 0;
    [self.view addSubview:picker]; self.channelPicker = picker;

    UIButton *qualityBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    qualityBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [qualityBtn setTitle:[NSString stringWithFormat:@"音质：%@", [RecorderEngine qualityDescription:[RecorderEngine shared].quality]]
                forState:UIControlStateNormal];
    qualityBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [qualityBtn addTarget:self action:@selector(chooseQuality) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:qualityBtn]; self.qualityButton = qualityBtn;

    // 自动录音开关
    UILabel *autoLbl = [[UILabel alloc] init];
    autoLbl.translatesAutoresizingMaskIntoConstraints = NO;
    autoLbl.text = @"来电自动录音（电话/FaceTime）";
    autoLbl.font = [UIFont systemFontOfSize:13];
    [self.view addSubview:autoLbl];
    UISwitch *sw = [[UISwitch alloc] init];
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    sw.on = [CallMonitor shared].autoRecordEnabled;
    [sw addTarget:self action:@selector(toggleAuto:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:sw]; self.autoSwitch = sw;

    // ===== 微信/QQ 手动录音助手（通知栏 + 悬浮球）=====
    UIButton *notifyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    notifyBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [notifyBtn setTitle:@"① 启用微信/QQ 通知栏录音按钮" forState:UIControlStateNormal];
    notifyBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    notifyBtn.backgroundColor = [UIColor colorWithRed:0.13 green:0.42 blue:0.85 alpha:0.12];
    notifyBtn.layer.cornerRadius = 8;
    [notifyBtn addTarget:self action:@selector(enableManualAssistant) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:notifyBtn]; self.notifyBtn = notifyBtn;

    UILabel *floatLbl = [[UILabel alloc] init];
    floatLbl.translatesAutoresizingMaskIntoConstraints = NO;
    floatLbl.text = @"② 悬浮球（浮在微信上，可拖动）";
    floatLbl.font = [UIFont systemFontOfSize:13];
    [self.view addSubview:floatLbl];
    UISwitch *floatSw = [[UISwitch alloc] init];
    floatSw.translatesAutoresizingMaskIntoConstraints = NO;
    floatSw.on = NO;
    [floatSw addTarget:self action:@selector(toggleFloatBall:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:floatSw]; self.floatSwitch = floatSw;

    // 微信通话自动录音（需先注入 WeChatCallHook.dylib 到微信）
    UILabel *wxLbl = [[UILabel alloc] init];
    wxLbl.translatesAutoresizingMaskIntoConstraints = NO;
    wxLbl.text = @"③ 微信/QQ通话自动录音（免注入）";
    wxLbl.font = [UIFont systemFontOfSize:13];
    [self.view addSubview:wxLbl];
    UISwitch *wxSw = [[UISwitch alloc] init];
    wxSw.translatesAutoresizingMaskIntoConstraints = NO;
    wxSw.on = [AppCallMonitor shared].thirdPartyAutoEnabled;
    [wxSw addTarget:self action:@selector(toggleWeChatAuto:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:wxSw]; self.wxSwitch = wxSw;

    UILabel *status = [[UILabel alloc] init];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.text = @"准备就绪";
    status.textAlignment = NSTextAlignmentCenter;
    status.font = [UIFont systemFontOfSize:12];
    status.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:status]; self.statusLabel = status;

    UILabel *level = [[UILabel alloc] init];
    level.translatesAutoresizingMaskIntoConstraints = NO;
    level.text = @"电平 自己:－  对方:－";
    level.textAlignment = NSTextAlignmentCenter;
    level.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    [self.view addSubview:level]; self.levelLabel = level;

    UIButton *recordBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    recordBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [recordBtn setTitle:@"●  开始录音" forState:UIControlStateNormal];
    [recordBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    recordBtn.titleLabel.font = [UIFont boldSystemFontOfSize:19];
    recordBtn.backgroundColor = [UIColor systemRedColor];
    recordBtn.layer.cornerRadius = 28;
    [recordBtn addTarget:self action:@selector(toggleRecord) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:recordBtn]; self.recordButton = recordBtn;

    UILabel *tips = [[UILabel alloc] init];
    tips.translatesAutoresizingMaskIntoConstraints = NO;
    tips.text = @"「双方」模式：左声道=你 右声道=对方 · 长按文件转文字/分享";
    tips.textAlignment = NSTextAlignmentCenter;
    tips.font = [UIFont systemFontOfSize:10];
    tips.textColor = [UIColor tertiaryLabelColor];
    tips.numberOfLines = 0;
    [self.view addSubview:tips];

    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.delegate = self; tv.dataSource = self;
    [tv registerClass:[UITableViewCell class] forCellReuseIdentifier:@"Cell"];
    [self.view addSubview:tv]; self.tableView = tv;

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [picker.topAnchor constraintEqualToAnchor:g.topAnchor constant:12],
        [picker.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [picker.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [qualityBtn.topAnchor constraintEqualToAnchor:picker.bottomAnchor constant:10],
        [qualityBtn.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [autoLbl.topAnchor constraintEqualToAnchor:qualityBtn.bottomAnchor constant:10],
        [autoLbl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [sw.topAnchor constraintEqualToAnchor:qualityBtn.bottomAnchor constant:6],
        [sw.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [notifyBtn.topAnchor constraintEqualToAnchor:autoLbl.bottomAnchor constant:12],
        [notifyBtn.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [notifyBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [notifyBtn.heightAnchor constraintEqualToConstant:38],
        [floatLbl.topAnchor constraintEqualToAnchor:notifyBtn.bottomAnchor constant:12],
        [floatLbl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [floatSw.topAnchor constraintEqualToAnchor:notifyBtn.bottomAnchor constant:8],
        [floatSw.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [wxLbl.topAnchor constraintEqualToAnchor:floatLbl.bottomAnchor constant:12],
        [wxLbl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [wxSw.topAnchor constraintEqualToAnchor:floatLbl.bottomAnchor constant:8],
        [wxSw.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [status.topAnchor constraintEqualToAnchor:wxLbl.bottomAnchor constant:12],
        [status.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [status.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [level.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:4],
        [level.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [level.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [recordBtn.topAnchor constraintEqualToAnchor:level.bottomAnchor constant:12],
        [recordBtn.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [recordBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [recordBtn.heightAnchor constraintEqualToConstant:56],
        [tips.topAnchor constraintEqualToAnchor:recordBtn.bottomAnchor constant:8],
        [tips.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [tips.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [tv.topAnchor constraintEqualToAnchor:tips.bottomAnchor constant:8],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)toggleAuto:(UISwitch *)sw {
    [CallMonitor shared].autoRecordEnabled = sw.on;
    [self alert:sw.on ? @"已开启：电话/来电接通时自动开始双路录音，挂断自动保存。"
                      : @"已关闭自动录音。"
          title:@"来电自动录音"];
}

// 启用通知栏手动控制：授权后发一条常驻通知，微信/QQ 通话时下拉点按钮即可录音
- (void)enableManualAssistant {
    [[ManualControl shared] requestPermissionAndEnable];
    [self alert:@"已向通知中心投递『手动通话录音助手』。\n\n用法：微信/QQ 来电接通后，下拉通知中心，点通知上的『开始/停止录音』按钮即可，无需切回本 App。录音完成会再推一条结果通知。\n\n注：如果通知没出现，去 设置-通知 里允许本 App 通知。"
          title:@"微信/QQ 手动录音助手"];
}

// 微信/QQ 通话自动录音开关（官方同款免注入检测）
- (void)toggleWeChatAuto:(UISwitch *)sw {
    [AppCallMonitor shared].thirdPartyAutoEnabled = sw.on;
    [self alert:sw.on
        ? @"已开启【持续录音】：App 启动后全程双路录音（麦克风+对方），每5分钟自动存一个文件，只保留最近24段。\n\n微信/QQ/普通电话的通话声音都会被录进去——不依赖任何通话检测信号。请保持本 App 在后台运行（不要强杀）。\n\n打完电话点顶部『微信日志』，看最后几行的 mic/spk 电平：有数值说明录到了声音。"
        : @"已关闭持续录音，已停止并保存当前段。"
          title:@"持续录音"];
}

// 悬浮球开关（TrollStore 权限下可浮在微信/QQ 之上）
- (void)toggleFloatBall:(UISwitch *)sw {
    if (sw.on) {
        [[FloatingBall shared] show];
        [self alert:@"悬浮球已显示，可拖到屏幕任意位置。\n\n微信/QQ 通话时点一下『录』开始、点『停』保存。\n\n注：悬浮球能否盖在微信之上取决于系统版本；盖不住就用通知栏按钮，那个一定可用。"
              title:@"悬浮球"];
    } else {
        [[FloatingBall shared] hide];
    }
}

- (void)chooseQuality {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"输出音质 / 体积"
                                                                  message:@" AAC/m4a 编码：采样率越低文件越小，下次录音生效。"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (int i = 0; i <= 2; i++) {
        TRQuality q = (TRQuality)i;
        NSString *mark = ([RecorderEngine shared].quality == q) ? @"✓ " : @"";
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@%@", mark, [RecorderEngine qualityDescription:q]]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            [RecorderEngine shared].quality = q;
            [self.qualityButton setTitle:[NSString stringWithFormat:@"音质：%@", [RecorderEngine qualityDescription:q]]
                                forState:UIControlStateNormal];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.qualityButton;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 录音

- (void)startRecordAuto:(BOOL)autoTriggered {
    if ([RecorderEngine shared].isRecording) return;
    self.autoRecording = autoTriggered;
    TRChannel ch = TRChannelSystemAudio;
    if (self.channelPicker.selectedSegmentIndex == 1) ch = TRChannelMicrophone;
    else if (self.channelPicker.selectedSegmentIndex == 2) ch = TRChannelSpeaker;

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *prefix = autoTriggered ? @"auto_call" : @"call";
    NSString *name = [NSString stringWithFormat:@"%@_%@.m4a", prefix, [fmt stringFromDate:[NSDate date]]];
    NSURL *url = [[self docsURL] URLByAppendingPathComponent:name];

    NSError *error = nil;
    BOOL ok = [[RecorderEngine shared] startWithChannel:ch fileURL:url error:&error];
    if (!ok) { [self alert:error.localizedDescription ?: @"启动失败" title:@"无法录音"]; return; }

    self.channelPicker.enabled = NO; self.qualityButton.enabled = NO;
    [self.recordButton setTitle:@"■  停止录音" forState:UIControlStateNormal];
    self.recordButton.backgroundColor = [UIColor colorWithRed:0.85 green:0.20 blue:0.20 alpha:1.0];
    self.statusLabel.text = autoTriggered ? @"📞 来电自动录音中…" : @"录音中 · 双路采集中";
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.3 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)toggleRecord {
    if ([RecorderEngine shared].isRecording) [self stopRecord];
    else [self startRecordAuto:NO];
}

- (void)stopRecord {
    if (![RecorderEngine shared].isRecording) return;
    [[RecorderEngine shared] stop];   // 混音异步在引擎内做，完成后走 delegate
    [self.timer invalidate]; self.timer = nil;
    [self.recordButton setTitle:@"●  开始录音" forState:UIControlStateNormal];
    self.recordButton.backgroundColor = [UIColor systemRedColor];
    self.channelPicker.enabled = YES; self.qualityButton.enabled = YES;
    self.statusLabel.text = @"正在合成 m4a…";
}

#pragma mark 自动录音通知

- (void)autoStart { [self startRecordAuto:YES]; }
- (void)autoStop {
    if ([RecorderEngine shared].isRecording && self.autoRecording) [self stopRecord];
}

#pragma mark RecorderEngineDelegate

- (void)recorderDidFinishWithURL:(NSURL *)url micLevel:(float)micLevel speakerLevel:(float)spkLevel {
    NSString *mic = micLevel < 0.001 ? @"无" : [NSString stringWithFormat:@"%.2f", micLevel];
    NSString *spk = spkLevel < 0.001 ? @"无" : [NSString stringWithFormat:@"%.2f", spkLevel];
    NSString *body = [NSString stringWithFormat:@"自己:%@ 对方:%@ · %@", mic, spk, url.lastPathComponent];
    [[NSNotificationCenter defaultCenter] postNotificationName:ManualRecordingDoneNotification
                                                        object:nil
                                                      userInfo:@{ @"body": body }];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self loadFiles];
        self.statusLabel.text = [NSString stringWithFormat:@"已保存 · 自己:%@ 对方:%@", mic, spk];
        [[FloatingBall shared] tapFromBackground];
    });
}
- (void)recorderDidFailWithMessage:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = @"合成失败";
        [self alert:msg title:@"录音处理失败"];
    });
}

- (void)tick {
    RecorderEngine *e = [RecorderEngine shared];
    NSString *barM = [self bar:e.micLevel];
    NSString *barS = [self bar:e.speakerLevel];
    self.levelLabel.text = [NSString stringWithFormat:@"自己 %@ | 对方 %@", barM, barS];
}
- (NSString *)bar:(float)level {
    int blocks = MIN(12, (int)(level * 12));
    if (blocks <= 0) return @"－";
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < blocks; i++) [s appendString:@"█"];
    return s;
}

#pragma mark - 文件

- (NSURL *)docsURL {
    return [NSURL fileURLWithPath:NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                     NSUserDomainMask, YES).firstObject
                      isDirectory:YES];
}
- (void)loadFiles {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *items = [fm contentsOfDirectoryAtURL:[self docsURL]
                         includingPropertiesForKeys:@[NSURLCreationDateKey]
                                            options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSMutableArray *result = [NSMutableArray array];
    for (NSURL *u in items) {
        NSString *ext = u.pathExtension.lowercaseString;
        // 只显示最终 m4a，隐藏中间 CAF
        if ([ext isEqualToString:@"m4a"] || [ext isEqualToString:@"caf"]) {
            if ([u.lastPathComponent containsString:@"_mic"] || [u.lastPathComponent containsString:@"_spk"]) continue;
            [result addObject:u];
        }
    }
    [result sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *da, *db;
        [a getResourceValue:&da forKey:NSURLCreationDateKey error:nil];
        [b getResourceValue:&db forKey:NSURLCreationDateKey error:nil];
        return [db compare:da];
    }];
    self.files = result;
    [self.tableView reloadData];
}

#pragma mark - 表格

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.files.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:ip];
    NSURL *url = self.files[ip.row];
    NSDate *date = nil; [url getResourceValue:&date forKey:NSURLCreationDateKey error:nil];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init]; fmt.dateFormat = @"MM-dd HH:mm";
    NSString *ts = date ? [fmt stringFromDate:date] : @"";
    NSTimeInterval dur = 0;
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:nil];
    if (p) dur = p.duration;
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil];
    NSInteger kb = (NSInteger)([attr[NSFileSize] unsignedLongLongValue] / 1024);
    cell.textLabel.text = [NSString stringWithFormat:@"%@  (%02ld:%02ld · %ld KB)",
                           ts, (long)((NSInteger)dur/60), (long)((NSInteger)dur%60), (long)kb];
    cell.detailTextLabel.text = url.lastPathComponent;
    cell.accessoryType = (self.playingIndex == ip.row) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= self.files.count) return;
    if (self.player.isPlaying && self.playingIndex == ip.row) {
        [self.player stop]; self.player = nil; self.playingIndex = -1; [t reloadData]; return;
    }
    NSError *error = nil;
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:self.files[ip.row] error:&error];
    if (!p) { [self alert:error.localizedDescription ?: @"文件可能为空" title:@"播放失败"]; return; }
    p.delegate = self; [p play]; self.player = p; self.playingIndex = ip.row; [t reloadData];
}
- (BOOL)tableView:(UITableView *)t canEditRowAtIndexPath:(NSIndexPath *)ip { return YES; }
- (void)tableView:(UITableView *)t commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete || ip.row >= self.files.count) return;
    NSURL *url = self.files[ip.row];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"录音操作" message:url.lastPathComponent
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"转文字（中文）" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [self transcribeURL:url]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"分享导出" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        av.popoverPresentationController.sourceView = self.view;
        [self presentViewController:av animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil]; [self loadFiles];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = [t cellForRowAtIndexPath:ip];
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 转文字

- (void)transcribeURL:(NSURL *)url {
    if (!self.speechRecognizer.available) { [self alert:@"设备暂不支持中文语音识别" title:@"无法转文字"]; return; }
    if ([SFSpeechRecognizer authorizationStatus] != SFSpeechRecognizerAuthorizationStatusAuthorized) {
        [self alert:@"请在 设置-隐私-语音识别 中允许本 App。" title:@"需要授权"]; return;
    }
    if (self.speechTask) { [self.speechTask cancel]; self.speechTask = nil; }
    self.statusLabel.text = @"语音识别中…";
    SFSpeechURLRecognitionRequest *request = [[SFSpeechURLRecognitionRequest alloc] initWithURL:url];
    if (@available(iOS 14.0, *)) request.requiresOnDeviceRecognition = YES;
    __weak typeof(self) wf = self;
    self.speechTask = [self.speechRecognizer recognitionTaskWithRequest:request
        resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        if (error) { dispatch_async(dispatch_get_main_queue(), ^{ [wf alert:error.localizedDescription title:@"转文字失败"]; }); return; }
        if (result.isFinal) {
            NSString *text = result.bestTranscription.formattedString;
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"转文字结果" message:(text.length?text:@"无内容")
                                                                    preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *a) { [UIPasteboard generalPasteboard].string = text; }]];
                [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [wf presentViewController:ac animated:YES completion:nil];
            });
        }
    }];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    self.playingIndex = -1; self.player = nil; [self.tableView reloadData];
}

- (void)alert:(NSString *)msg title:(NSString *)title {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
