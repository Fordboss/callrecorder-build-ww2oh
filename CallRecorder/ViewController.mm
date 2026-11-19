#import "ViewController.h"
#import "RecorderEngine.h"
#import "CallMonitor.h"
#import "ManualControl.h"
#import "FloatingBall.h"
#import "DarwinMonitor.h"
#import "AppCallMonitor.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Speech/Speech.h>
#import <stdlib.h>

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
@property (nonatomic, strong) NSTimer *uiTimer;    // v9.6 界面同步（常驻录音也靠它显示进度）
@property (nonatomic, assign) BOOL autoRecording;   // 本次录音是否由来电自动触发

@property (nonatomic, strong) SFSpeechRecognizer *speechRecognizer;
@property (nonatomic, strong) SFSpeechRecognitionTask *speechTask;
@end

@implementation ViewController

// v9.4 ★关键修复：自动模式是常驻分段录音，切回 App 必须重新扫目录，
// 否则通话后看到的还是打开 App 那一刻的旧列表（旧版「没有产生文件」的直接原因之一）。
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadFiles];
    [self startUITimer];   // v9.6：常驻录音在后台跑，界面必须持续跟随
    // v9.6：每次回到 App 都确认常驻录音在跑 —— 被播放/来电/中断掐断后自动拉起
    [[AppCallMonitor shared] ensureContinuousRecording];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.uiTimer invalidate]; self.uiTimer = nil;
}

// ===== v9.6 界面同步 =====
// 旧版根因：常驻录音由 AppCallMonitor 自行启动，从不经过 startRecordAuto:，
// 而按钮文案/颜色、电平条、状态文字全都在 startRecordAuto: 里才设置 →
// 常驻录音明明在跑（每 60 秒出一个 WAV），界面却一直停在「● 开始录音」、电平「－」。
- (void)startUITimer {
    if (self.uiTimer) return;
    self.uiTimer = [NSTimer timerWithTimeInterval:0.5 target:self selector:@selector(syncResidentUI)
                                        userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.uiTimer forMode:NSRunLoopCommonModes];
    [self syncResidentUI];
}

- (void)syncResidentUI {
    RecorderEngine *e = [RecorderEngine shared];
    if (![self autoModeOn]) {
        // 自动开关关闭 → 交回手动模式，按钮由 startRecordAuto/stopRecord 管理
        if (!e.isRecording && !self.timer) {
            [self.recordButton setTitle:@"●  开始录音" forState:UIControlStateNormal];
            self.recordButton.backgroundColor = [UIColor systemRedColor];
            self.channelPicker.enabled = YES;
            self.qualityButton.enabled = YES;
            self.levelLabel.text = @"电平 自己:－  对方:－";
        }
        return;
    }
    self.channelPicker.enabled = NO;   // 常驻模式固定走"自己"这一路，通道选择无效
    if (e.isRecording) {
        NSInteger seg = [e currentSegmentIndex];
        double sec = [e currentSegmentSeconds];
        if (seg > 0) {
            // 正在录一段真人声：按钮上的秒数每秒往前走，一眼确认在录
            [self.recordButton setTitle:[NSString stringWithFormat:@"● 录音中  第%ld段 %02ld:%02ld",
                                         (long)seg, (long)((NSInteger)sec / 60), (long)((NSInteger)sec % 60)]
                               forState:UIControlStateNormal];
            self.recordButton.backgroundColor = [UIColor colorWithRed:0.85 green:0.20 blue:0.20 alpha:1.0];
            self.statusLabel.text = [NSString stringWithFormat:@"正在录人声 · 已封存 %ld 段 · 说完静音 15 秒自动存",
                                     (long)[e sealedSegmentCount]];
        } else {
            // 待机：没人说话就不建文件，这是 v9.6 专门修「没通话也一堆文件」
            [self.recordButton setTitle:@"◉ 待命中 · 检测到说话才录" forState:UIControlStateNormal];
            self.recordButton.backgroundColor = [UIColor colorWithRed:0.20 green:0.45 blue:0.85 alpha:1.0];
            self.statusLabel.text = [NSString stringWithFormat:
                @"待命中：没有通话就不产生任何文件 · 已封存 %ld 段", (long)[e sealedSegmentCount]];
        }
        self.recordButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        // v9.7：两路分别显示，能直接看出主路(-2 系统输出)有没有收到声音
        self.levelLabel.text = [NSString stringWithFormat:@"主路 %@ | 自己 %@",
                                [self bar:[e uiSystemLevel]], [self bar:[e uiMicOnlyLevel]]];
        if (![e sysChannelAlive]) {
            self.statusLabel.text = @"⚠ 系统输出通道没建起来，本次只能录到自己";
        }
    } else {
        [self.recordButton setTitle:@"⚠ 常驻录音已停 · 重建中" forState:UIControlStateNormal];
        self.recordButton.backgroundColor = [UIColor systemOrangeColor];
        self.levelLabel.text = @"自己 － | 对方 未启用";
        self.statusLabel.text = @"看门狗正在重启常驻录音…（若长时间不回，去设置里确认麦克风权限）";
    }
}

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
    // v9.5：常驻录音每滚动出一个 WAV 就刷新列表（前台也实时可见）
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onSegmentRolled:)
                                                 name:@"CallRecorderSegmentRolled" object:nil];
}

- (void)onSegmentRolled:(NSNotification *)n {
    dispatch_async(dispatch_get_main_queue(), ^{ [self loadFiles]; });
}

// v9.5：自动常驻录音开关是否开启（与 AppCallMonitor 共用同一个 key）
- (BOOL)autoModeOn {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    return [ud objectForKey:@"CallRecorderThirdPartyAuto"] ? [ud boolForKey:@"CallRecorderThirdPartyAuto"] : YES;
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
    wxLbl.text = @"③ 微信/QQ自动录音（v9.7 双tap·与v6.0同配方）";
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
    // v9.6：开关一变立刻同步按钮/电平/状态，不用等下一个 0.5 秒 tick
    [self startUITimer];
    [self syncResidentUI];
    [self loadFiles];
    [self alert:sw.on
        ? @"已开启【v9.7 自动录音】：装上即用，无需注入、无需脱壳。\n\n★这一版是回到 v6.0 的录音配方。你反馈「6.0 能自动录，现在都不能拉起」，我回去对比了 v6.0 的源码，找到唯一的结构性差异：\n\nv6.0 用【私有 tap】：-2 系统输出 + -3 麦克风，两条 AudioQueue 直接接 tap，全程【不激活 AVAudioSession】。\n\nv9.4 之后改成了【标准麦克风队列 + setActive:YES + PlayAndRecord】——这等于主动向系统申请录音会话。微信/QQ 通话一接通就把这个会话整个抢走，我们的队列立刻收到 Start='!pri'（无法启动），回调数永远停在原地，所以通话期间一个字节都录不到。\n\nv9.7 恢复 tap 配方：主路 -2 系统输出负责出文件（通话中对方声音在这里），副路 -3 麦克风只测电平不出文件（避免两个文件分不清）。全程不碰 AVAudioSession。\n\n另外还修了两处：① 中断结束后必须重建队列（旧版只打了一句“队列仍在，继续使用”，队列从此永久不回调）；② 发声判定从“逐采样比门限”改成“0.1秒块能量”，旧判定因为人声波形过零点大量漏检，会出现“明明有声音却永远不建文件”。"
        : @"已关闭自动录音，当前段已封存为可播放的 WAV。"
          title:@"v9.7 自动录音"];
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
            // v9.6：常驻录音只在启动时读一次档位，不重启永远不生效
            [[AppCallMonitor shared] restartContinuousRecording];
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
    NSString *name = [NSString stringWithFormat:@"%@_%@.wav", prefix, [fmt stringFromDate:[NSDate date]]];
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
    // ★v9.5 隔离：自动常驻录音运行时，手动按钮绝不能停掉它
    if ([self autoModeOn]) {
        // v9.6：按钮现在实时显示常驻录音进度，点一下给出可核对的实时数据
        RecorderEngine *e = [RecorderEngine shared];
        [self alert:[NSString stringWithFormat:
                @"常驻录音开关（③）是开着的，所以按钮被常驻录音接管：\n\n"
                @"运行状态：%@\n当前第 %ld 段，本段已录 %.1f 秒\n采集回调累计：%ld 次\n采样率：%ld Hz\n\n"
                @"文件每满 60 秒封存一个，所以通话超过 1 分钟才会在列表里看到新文件。\n\n"
                @"若要手动单点录音，请先把开关③关掉。",
                e.isRecording ? @"正常录音中" : @"未在录音（看门狗正在重建）",
                (long)MAX((NSInteger)1, [e currentSegmentIndex]), [e currentSegmentSeconds],
                (long)[e callbackCount], (long)[e outputSampleRate]]
              title:@"常驻录音运行中"];
        return;
    }
    if ([RecorderEngine shared].isRecording) [self stopRecord];
    else [self startRecordAuto:NO];
}

- (void)stopRecord {
    if ([self autoModeOn]) return;   // ★v9.5 保护常驻录音
    if (![RecorderEngine shared].isRecording) return;
    [[RecorderEngine shared] stop];   // 混音异步在引擎内做，完成后走 delegate
    [self.timer invalidate]; self.timer = nil;
    [self.recordButton setTitle:@"●  开始录音" forState:UIControlStateNormal];
    self.recordButton.backgroundColor = [UIColor systemRedColor];
    self.channelPicker.enabled = YES; self.qualityButton.enabled = YES;
    self.statusLabel.text = @"正在合成 m4a…";
}

#pragma mark 自动录音通知

- (void)autoStart { if ([self autoModeOn]) return; [self startRecordAuto:YES]; }
- (void)autoStop {
    // ★v9.5：来电/挂断通知不得停止常驻录音（旧版「第一个通话后就没文件」的元凶之一）
    if ([self autoModeOn]) return;
    if ([RecorderEngine shared].isRecording && self.autoRecording) [self stopRecord];
}

#pragma mark RecorderEngineDelegate

- (void)recorderDidFinishWithURL:(NSURL *)url micLevel:(float)micLevel speakerLevel:(float)spkLevel {
    NSString *mic = micLevel < 0.001 ? @"无" : [NSString stringWithFormat:@"%.2f", micLevel];
    NSString *spk = spkLevel < 0.001 ? @"无" : [NSString stringWithFormat:@"%.2f", spkLevel];
    BOOL autoSegment = [url.lastPathComponent hasPrefix:@"rec_"];
    if (!autoSegment) {
        NSString *body = [NSString stringWithFormat:@"自己:%@ 对方:%@ · %@", mic, spk, url.lastPathComponent];
        [[NSNotificationCenter defaultCenter] postNotificationName:ManualRecordingDoneNotification
                                                            object:nil
                                                          userInfo:@{ @"body": body }];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self loadFiles];
        self.statusLabel.text = autoSegment
            ? [NSString stringWithFormat:@"自动段已保存 · 自己:%@ 对方:%@", mic, spk]
            : [NSString stringWithFormat:@"已保存 · 自己:%@ 对方:%@", mic, spk];
        if (!autoSegment) [[FloatingBall shared] tapFromBackground];
    });
}
- (void)recorderDidFailWithMessage:(NSString *)msg {
    // v9.4：自动模式每 60 秒一段，不能每段弹一次窗；只刷新列表 + 状态文字
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL autoOn = [ud objectForKey:@"CallRecorderThirdPartyAuto"] ? [ud boolForKey:@"CallRecorderThirdPartyAuto"] : YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self loadFiles];
        self.statusLabel.text = autoOn ? @"自动段无声音数据（文件已保留）" : @"合成失败";
        if (!autoOn) [self alert:msg title:@"录音处理失败"];
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
        // 只显示最终成品，隐藏三路临时文件
        if ([ext isEqualToString:@"wav"] || [ext isEqualToString:@"m4a"] || [ext isEqualToString:@"caf"]) {
            NSString *n = u.lastPathComponent;
            if ([n containsString:@"_mic"] || [n containsString:@"_spk"] ||
                [n containsString:@"_app"] || [n containsString:@"_sys"] ||
                [n containsString:@"_mix"] || [n containsString:@"_direct"]) continue;
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
        [self.player stop]; self.player = nil; self.playingIndex = -1;
        [self restoreRecordSession];   // ★v9.6 不能 deactivate，否则常驻录音被掐断
        [t reloadData]; return;
    }
    // v9.7 ★播放策略随通道方案一起改：
    // v9.7 的录音走私有 tap，全程【不激活 AVAudioSession】（和 v6.0 一致）。
    // 所以播放时反而必须自己把会话激活成 Playback + 扬声器，否则听筒/静音键会吞掉声音。
    // 播完立刻 setActive:NO 把会话还给系统 —— tap 不依赖会话，关掉不影响采集。
    AVAudioSession *sess = [AVAudioSession sharedInstance];
    [sess setCategory:AVAudioSessionCategoryPlayback error:nil];
    [sess setActive:YES error:nil];
    [sess overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:nil];
    NSError *error = nil;
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:self.files[ip.row] error:&error];
    if (!p) { [self restoreRecordSession]; [self alert:error.localizedDescription ?: @"文件可能为空" title:@"播放失败"]; return; }
    p.delegate = self;
    p.volume = 1.0;                     // ← 确保不是被降到很低
    [p prepareToPlay];
    if (![p play]) {
        [self restoreRecordSession];
        [self alert:@"播放器未能启动，请用「分享导出」发到微信里试听" title:@"播放失败"];
        return;
    }
    self.player = p; self.playingIndex = ip.row; [t reloadData];
}

// v9.7 ★播完把会话彻底还给系统。
// v9.7 的录音是私有 tap（不激活会话），这里 setActive:NO 完全不影响采集；
// 反而一直占着 Playback 会干扰微信/QQ 通话本身的音频路由。
- (void)restoreRecordSession {
    AVAudioSession *sess = [AVAudioSession sharedInstance];
    [sess overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:nil];
    [sess setActive:NO error:nil];
}
- (BOOL)tableView:(UITableView *)t canEditRowAtIndexPath:(NSIndexPath *)ip { return YES; }
- (void)tableView:(UITableView *)t commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete || ip.row >= self.files.count) return;
    NSURL *url = self.files[ip.row];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"录音操作" message:url.lastPathComponent
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"文件体检（看有没有声音）" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [self inspectURL:url]; }]];
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

#pragma mark - 文件体检（v9.2：一次区分「文件静音」还是「播放静音」）

- (void)inspectURL:(NSURL *)url {
    UInt64 bytes = [[[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil][NSFileSize] unsignedLongLongValue];
    ExtAudioFileRef f = NULL;
    OSStatus st = ExtAudioFileOpenURL((__bridge CFURLRef)url, &f);
    if (st != noErr || !f) {
        [self alert:[NSString stringWithFormat:@"文件大小 %llu B\n无法解码读取 (st=%d)\n\n若只有几十字节 → 是空文件；\n若几百 KB 却打不开 → 换「分享导出」用别的播放器试。",
                     bytes, (int)st] title:@"文件体检"];
        return;
    }
    AudioStreamBasicDescription client = {0};
    client.mSampleRate = 44100;
    client.mFormatID = kAudioFormatLinearPCM;
    client.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    client.mFramesPerPacket = 1;
    client.mChannelsPerFrame = 1;
    client.mBitsPerChannel = 32;
    client.mBytesPerFrame = 4;
    client.mBytesPerPacket = 4;
    ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);

    const UInt32 kBufFrames = 8192;
    Float32 *buf = (Float32 *)calloc(kBufFrames, sizeof(Float32));
    float peak = 0; UInt64 readFrames = 0, nonZero = 0;
    if (buf) {
        AudioBufferList abl = {0};
        abl.mNumberBuffers = 1;
        abl.mBuffers[0].mNumberChannels = 1;
        abl.mBuffers[0].mData = buf;
        while (readFrames < 60ULL * 60 * 44100) {
            abl.mBuffers[0].mDataByteSize = kBufFrames * sizeof(Float32);
            UInt32 n = kBufFrames;
            if (ExtAudioFileRead(f, &n, &abl) != noErr || n == 0) break;
            for (UInt32 i = 0; i < n; i++) {
                Float32 v = buf[i];
                float a = v < 0 ? -v : v;
                if (a > peak) peak = a;
                if (a > 0.0001f) nonZero++;
            }
            readFrames += n;
        }
        free(buf);
    }
    ExtAudioFileDispose(f);
    NSString *verdict = (peak > 0.001f)
        ? @"✅ 文件里【有声音数据】。如果耳朵听不到，是播放端被静音键/输出路由吞了 —— v9.2 已在播放前激活 AVAudioSession 修好。"
        : @"❌ 文件里几乎没有声音数据（整段静音）。这是出文件链的问题 —— v9.2 已改为 PCM WAV 回调直写，不再经过 AAC 编码。";
    [self alert:[NSString stringWithFormat:@"%@\n\n大小：%llu B\n时长：约 %.1f 秒\n读到帧数：%llu\n非零样本：%llu\n峰值：%.4f",
                 verdict, bytes, (double)readFrames / 44100.0, readFrames, nonZero, peak]
          title:@"文件体检"];
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
    self.playingIndex = -1; self.player = nil;
    [self restoreRecordSession];    // ★v9.6 播完交还会话，不能掐断常驻录音
    [self.tableView reloadData];
}

- (void)alert:(NSString *)msg title:(NSString *)title {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
