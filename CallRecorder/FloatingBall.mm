#import "FloatingBall.h"
#import "RecorderEngine.h"
#import "ManualControl.h"
#import <UIKit/UIKit.h>

// TrollStore 的 platform-application 权限允许高 windowLevel 的 UIWindow 浮在其他 App 之上。
// 普通沙盒 App 的窗口切后台即被遮挡，但巨魔签名坐实权限后可跨 App 显示。
@interface FloatingBall ()
@property (nonatomic, strong) UIWindow *floatWindow;
@property (nonatomic, strong) UIButton *ball;
@property (nonatomic, assign) BOOL isShown;
@end

@implementation FloatingBall

+ (instancetype)shared {
    static FloatingBall *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (void)show {
    if (self.isShown) return;

    CGFloat size = 60;
    CGFloat y = [UIScreen mainScreen].bounds.size.height * 0.35;
    UIWindow *win = [[UIWindow alloc] initWithFrame:CGRectMake(16, y, size, size)];
    // 高于系统状态栏与绝大多数 App 窗口
    if (@available(iOS 13.0, *)) {
        win.windowLevel = UIWindowLevelStatusBar + 2500;
    } else {
        win.windowLevel = UIWindowLevelAlert + 2500;
    }
    win.backgroundColor = [UIColor clearColor];
    win.layer.cornerRadius = size / 2;
    win.clipsToBounds = YES;
    win.hidden = NO;
    self.floatWindow = win;

    UIButton *ball = [UIButton buttonWithType:UIButtonTypeCustom];
    ball.frame = win.bounds;
    ball.layer.cornerRadius = size / 2;
    ball.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.82];
    [ball setTitle:@"录" forState:UIControlStateNormal];
    [ball setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    ball.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    ball.layer.shadowColor = [UIColor blackColor].CGColor;
    ball.layer.shadowOpacity = 0.4;
    ball.layer.shadowRadius = 4;
    [ball addTarget:self action:@selector(ballTapped) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    [ball addGestureRecognizer:pan];
    [win addSubview:ball];
    self.ball = ball;

    self.isShown = YES;
    [self refreshAppearance];
    NSLog(@"[Ball] 悬浮球已显示");
}

- (void)hide {
    self.floatWindow.hidden = YES;
    self.floatWindow = nil;
    self.ball = nil;
    self.isShown = NO;
    NSLog(@"[Ball] 悬浮球已隐藏");
}

- (void)tapFromBackground { [self refreshAppearance]; }

- (void)drag:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.floatWindow];
    CGRect f = self.floatWindow.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    CGFloat maxX = [UIScreen mainScreen].bounds.size.width - f.size.width;
    CGFloat maxY = [UIScreen mainScreen].bounds.size.height - f.size.height;
    f.origin.x = MAX(0, MIN(maxX, f.origin.x));
    f.origin.y = MAX(0, MIN(maxY, f.origin.y));
    self.floatWindow.frame = f;
    [g setTranslation:CGPointZero inView:self.floatWindow];
}

- (void)ballTapped {
    RecorderEngine *engine = [RecorderEngine shared];
    if (engine.isRecording) {
        [engine stop];
    } else {
        // 文件名带 manual 前缀，与 App 内录音区分，都会被文件列表识别
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyyMMdd_HHmmss";
        NSString *name = [NSString stringWithFormat:@"float_%@.m4a", [fmt stringFromDate:[NSDate date]]];
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSURL *url = [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:name]];
        NSError *error = nil;
        BOOL ok = [[RecorderEngine shared] startWithChannel:TRChannelSystemAudio fileURL:url error:&error];
        NSLog(@"[Ball] 触发录音 %@ %@", ok ? @"成功" : @"失败", error.localizedDescription ?: @"");
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self refreshAppearance]; });
}

- (void)refreshAppearance {
    BOOL recording = [RecorderEngine shared].isRecording;
    self.ball.backgroundColor = recording
        ? [[UIColor colorWithRed:0.1 green:0.75 blue:0.3 alpha:1.0] colorWithAlphaComponent:0.88]
        : [[UIColor redColor] colorWithAlphaComponent:0.82];
    [self.ball setTitle:recording ? @"停" : @"录" forState:UIControlStateNormal];
}

@end
