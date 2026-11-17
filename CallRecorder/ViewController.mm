#import "ViewController.h"
#import "RecorderEngine.h"
#import <AVFoundation/AVFoundation.h>

@interface ViewController () <AVAudioPlayerDelegate, UITableViewDelegate, UITableViewDataSource>

@property (nonatomic, strong) UISegmentedControl *channelPicker;
@property (nonatomic, strong) UIButton   *recordButton;
@property (nonatomic, strong) UILabel    *statusLabel;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSURL *> *files;
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, assign) NSInteger playingIndex;
@property (nonatomic, strong) NSTimer *timer;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"通话录音机";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.playingIndex = -1;
    [self setupUI];
    [self loadFiles];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadFiles];
}

#pragma mark - UI

- (void)setupUI {
    UISegmentedControl *picker = [[UISegmentedControl alloc] initWithItems:@[@"通话双方", @"麦克风", @"扬声器"]];
    picker.translatesAutoresizingMaskIntoConstraints = NO;
    picker.selectedSegmentIndex = 0;
    [self.view addSubview:picker];
    self.channelPicker = picker;

    UILabel *status = [[UILabel alloc] init];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.text = @"准备就绪 · 16 kHz AAC 单声道（约 0.24 MB/分钟）";
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

        [status.topAnchor constraintEqualToAnchor:picker.bottomAnchor constant:12],
        [status.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [status.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [recordBtn.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:12],
        [recordBtn.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [recordBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [recordBtn.heightAnchor constraintEqualToConstant:56],

        [tv.topAnchor constraintEqualToAnchor:recordBtn.bottomAnchor constant:16],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
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
        self.statusLabel.text = @"已保存 · 16 kHz AAC 单声道";
        self.channelPicker.enabled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self loadFiles]; });
    } else {
        TRChannel channel = (TRChannel)self.channelPicker.selectedSegmentIndex;
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyyMMdd_HHmmss";
        NSString *name = [NSString stringWithFormat:@"call_%@.m4a", [fmt stringFromDate:[NSDate date]]];
        NSURL *url = [[self docsURL] URLByAppendingPathComponent:name];

        NSError *error = nil;
        BOOL ok = [[RecorderEngine shared] startWithChannel:channel fileURL:url error:&error];
        if (!ok) {
            [self alert:error.localizedDescription ?: @"启动失败" title:@"无法录音"];
            return;
        }
        self.channelPicker.enabled = NO;
        [self.recordButton setTitle:@"■  停止录音" forState:UIControlStateNormal];
        self.recordButton.backgroundColor = [UIColor colorWithRed:0.85 green:0.20 blue:0.20 alpha:1.0];
        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                                                     selector:@selector(tick) userInfo:nil repeats:YES];
    }
}

- (void)tick {
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceReferenceDate];
    self.statusLabel.text = @"录音中 · 16 kHz AAC 单声道（点击停止保存）";
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
        if ([u.pathExtension.lowercaseString isEqualToString:@"m4a"]) [result addObject:u];
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
    if (!p) { [self alert:error.localizedDescription title:@"播放失败"]; return; }
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
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"分享 / 删除录音"
                                                                  message:url.lastPathComponent
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
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
