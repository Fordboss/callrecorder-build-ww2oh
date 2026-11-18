#import "ViewController.h"
#import "RecorderEngine.h"
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

@interface ViewController () <AVAudioPlayerDelegate, UITableViewDelegate, UITableViewDataSource,
                              SFSpeechRecognizerDelegate>

@property (nonatomic, strong) UISegmentedControl *channelPicker;
@property (nonatomic, strong) UIButton   *recordButton;
@property (nonatomic, strong) UIButton   *qualityButton;
@property (nonatomic, strong) UILabel    *statusLabel;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSURL *> *files;
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, assign) NSInteger playingIndex;
@property (nonatomic, strong) NSTimer *timer;

@property (nonatomic, strong) SFSpeechRecognizer *speechRecognizer;
@property (nonatomic, strong) SFSpeechRecognitionTask *speechTask;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"通话录音机";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.playingIndex = -1;

    [self setupNavBar];
    [self setupUI];
    [self loadFiles];

    // 语音识别授权（静默请求，结果不影响其他功能）
    self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"zh-CN"]];
    self.speechRecognizer.delegate = self;
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        NSLog(@"语音识别授权状态: %ld", (long)status);
    }];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadFiles];
}

#pragma mark - 导航栏：导出诊断日志

- (void)setupNavBar {
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"诊断日志"
                                         style:UIBarButtonItemStylePlain
                                        target:self action:@selector(shareDebugLog)];
}

- (void)shareDebugLog {
    NSURL *url = [[RecorderEngine shared] debugLogURL];
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        [self alert:@"还没有日志，先录一次音再导出。" title:@"诊断日志"];
        return;
    }
    UIActivityViewController *av = [[UIActivityViewController alloc]
                                    initWithActivityItems:@[url] applicationActivities:nil];
    av.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:av animated:YES completion:nil];
}

#pragma mark - UI

- (void)setupUI {
    UISegmentedControl *picker = [[UISegmentedControl alloc] initWithItems:@[@"麦克风", @"扬声器/听筒"]];
    picker.translatesAutoresizingMaskIntoConstraints = NO;
    picker.selectedSegmentIndex = 0;
    [self.view addSubview:picker];
    self.channelPicker = picker;

    UIButton *qualityBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    qualityBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [qualityBtn setTitle:[NSString stringWithFormat:@"音质：%@", [RecorderEngine qualityDescription:[RecorderEngine shared].quality]]
                forState:UIControlStateNormal];
    qualityBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [qualityBtn addTarget:self action:@selector(chooseQuality) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:qualityBtn];
    self.qualityButton = qualityBtn;

    UILabel *status = [[UILabel alloc] init];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.text = @"准备就绪 · 点上方按钮切换音质";
    status.textAlignment = NSTextAlignmentCenter;
    status.font = [UIFont systemFontOfSize:12];
    status.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:status];
    self.statusLabel = status;

    UIButton *recordBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    recordBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [recordBtn setTitle:@"●  开始录音" forState:UIControlStateNormal];
    [recordBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    recordBtn.titleLabel.font = [UIFont boldSystemFontOfSize:19];
    recordBtn.backgroundColor = [UIColor systemRedColor];
    recordBtn.layer.cornerRadius = 28;
    [recordBtn addTarget:self action:@selector(toggleRecord) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:recordBtn];
    self.recordButton = recordBtn;

    UILabel *tips = [[UILabel alloc] init];
    tips.translatesAutoresizingMaskIntoConstraints = NO;
    tips.text = @"长按需录音文件：转文字 / 分享 / 删除";
    tips.textAlignment = NSTextAlignmentCenter;
    tips.font = [UIFont systemFontOfSize:11];
    tips.textColor = [UIColor tertiaryLabelColor];
    [self.view addSubview:tips];

    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.delegate = self;
    tv.dataSource = self;
    [tv registerClass:[UITableViewCell class] forCellReuseIdentifier:@"Cell"];
    [self.view addSubview:tv];
    self.tableView = tv;

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [picker.topAnchor constraintEqualToAnchor:g.topAnchor constant:12],
        [picker.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [picker.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],

        [qualityBtn.topAnchor constraintEqualToAnchor:picker.bottomAnchor constant:10],
        [qualityBtn.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [status.topAnchor constraintEqualToAnchor:qualityBtn.bottomAnchor constant:8],
        [status.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [status.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [recordBtn.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:12],
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

#pragma mark - 音质选择

- (void)chooseQuality {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"录音音质 / 体积"
                                                                  message:@"切换后下次录音生效。采样率越低，文件越小。"
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

- (void)toggleRecord {
    RecorderEngine *engine = [RecorderEngine shared];
    if (engine.isRecording) {
        [engine stop];
        [self.timer invalidate];
        self.timer = nil;
        [self.recordButton setTitle:@"●  开始录音" forState:UIControlStateNormal];
        self.recordButton.backgroundColor = [UIColor systemRedColor];
        float level = engine.peakLevel;
        self.statusLabel.text = level < 0.001f
            ? @"已保存 · ⚠️全程静音，用『扬声器/听筒』通道放声音试试"
            : [NSString stringWithFormat:@"已保存 · 峰值电平 %.3f ✅有声音", level];
        self.channelPicker.enabled = YES;
        self.qualityButton.enabled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self loadFiles]; });
    } else {
        // segmented: 0=麦克风 -> TRChannelMicrophone(1), 1=扬声器 -> TRChannelSpeaker(2)
        TRChannel channel = self.channelPicker.selectedSegmentIndex == 0
            ? TRChannelMicrophone : TRChannelSpeaker;
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyyMMdd_HHmmss";
        NSString *name = [NSString stringWithFormat:@"call_%@.caf", [fmt stringFromDate:[NSDate date]]];
        NSURL *url = [[self docsURL] URLByAppendingPathComponent:name];

        NSError *error = nil;
        BOOL ok = [[RecorderEngine shared] startWithChannel:channel fileURL:url error:&error];
        if (!ok) {
            [self alert:error.localizedDescription ?: @"启动失败" title:@"无法录音"];
            return;
        }
        self.channelPicker.enabled = NO;
        self.qualityButton.enabled = NO;
        [self.recordButton setTitle:@"■  停止录音" forState:UIControlStateNormal];
        self.recordButton.backgroundColor = [UIColor colorWithRed:0.85 green:0.20 blue:0.20 alpha:1.0];
        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                                                     selector:@selector(tick) userInfo:nil repeats:YES];
    }
}

- (void)tick {
    float level = [[RecorderEngine shared] peakLevel];
    NSString *bar = @"";
    int blocks = MIN(20, (int)(level * 20));
    for (int i = 0; i < blocks; i++) bar = [bar stringByAppendingString:@"█"];
    if (blocks == 0) bar = @"（静音）";
    self.statusLabel.text = [NSString stringWithFormat:@"录音中 · 电平 %.3f %@", level, bar];
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
                                            options:NSDirectoryEnumerationSkipsHiddenFiles
                                              error:nil];
    NSMutableArray *result = [NSMutableArray array];
    for (NSURL *u in items) {
        if ([u.pathExtension.lowercaseString isEqualToString:@"caf"]) [result addObject:u];
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

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.files.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
    NSURL *url = self.files[indexPath.row];
    NSDate *date = nil;
    [url getResourceValue:&date forKey:NSURLCreationDateKey error:nil];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"MM-dd HH:mm";
    NSString *t = date ? [fmt stringFromDate:date] : @"";
    NSTimeInterval duration = 0;
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:nil];
    if (p) duration = p.duration;
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil];
    NSInteger kb = (NSInteger)([attr[NSFileSize] unsignedLongLongValue] / 1024);
    cell.textLabel.text = [NSString stringWithFormat:@"%@  (%02ld:%02ld · %ld KB)",
                           t, (long)((NSInteger)duration / 60), (long)((NSInteger)duration % 60), (long)kb];
    cell.detailTextLabel.text = url.lastPathComponent;
    cell.accessoryType = (self.playingIndex == indexPath.row)
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= self.files.count) return;
    if (self.player.isPlaying && self.playingIndex == indexPath.row) {
        [self.player stop]; self.player = nil; self.playingIndex = -1;
        [tableView reloadData];
        return;
    }
    NSError *error = nil;
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:self.files[indexPath.row] error:&error];
    if (!p) { [self alert:error.localizedDescription title:@"播放失败（文件可能为空）"]; return; }
    p.delegate = self;
    [p play];
    self.player = p;
    self.playingIndex = indexPath.row;
    [tableView reloadData];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete || indexPath.row >= self.files.count) return;
    NSURL *url = self.files[indexPath.row];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"录音操作"
                                                                  message:url.lastPathComponent
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"转文字（中文）" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [self transcribeURL:url]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"播放" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [self playURL:url]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"分享导出" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        UIActivityViewController *av = [[UIActivityViewController alloc]
                                        initWithActivityItems:@[url] applicationActivities:nil];
        av.popoverPresentationController.sourceView = self.view;
        [self presentViewController:av animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        [self loadFiles];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)playURL:(NSURL *)url {
    NSError *error = nil;
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];
    if (!p) { [self alert:error.localizedDescription title:@"播放失败"]; return; }
    p.delegate = self;
    [p play];
    self.player = p;
}

#pragma mark - 语音转文字

- (void)transcribeURL:(NSURL *)url {
    if (!self.speechRecognizer || !self.speechRecognizer.available) {
        [self alert:@"当前设备/语言暂不支持语音识别，请确认已安装中文识别模型。" title:@"无法转文字"];
        return;
    }
    if ([SFSpeechRecognizer authorizationStatus] != SFSpeechRecognizerAuthorizationStatusAuthorized) {
        [self alert:@"请在 设置-隐私-语音识别 中允许本 App 使用语音识别。" title:@"需要授权"];
        return;
    }
    if (self.speechTask) { [self.speechTask cancel]; self.speechTask = nil; }

    self.statusLabel.text = @"语音识别中…（长音频可能需十几秒）";
    SFSpeechURLRecognitionRequest *request = [[SFSpeechURLRecognitionRequest alloc] initWithURL:url];
    // 优先设备端识别，不上传音频（iOS 15+ 中文支持设备端）
    if (@available(iOS 14.0, *)) request.requiresOnDeviceRecognition = YES;

    __weak typeof(self) weakSelf = self;
    self.speechTask = [self.speechRecognizer recognitionTaskWithRequest:request
                                                         resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf alert:error.localizedDescription ?: @"识别失败" title:@"转文字失败"];
            });
            return;
        }
        if (result.isFinal) {
            NSString *text = result.bestTranscription.formattedString;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (text.length == 0) {
                    [weakSelf alert:@"没有识别到语音内容（录音可能为空或声音太小）。" title:@"转文字结果"];
                    return;
                }
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"转文字结果"
                                                                           message:text
                                                                    preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault
                                                     handler:^(UIAlertAction *a) { [UIPasteboard generalPasteboard].string = text; }]];
                [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [weakSelf presentViewController:ac animated:YES completion:nil];
            });
        }
    }];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    self.playingIndex = -1;
    self.player = nil;
    [self.tableView reloadData];
}

#pragma mark - 工具

- (void)alert:(NSString *)msg title:(NSString *)title {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
