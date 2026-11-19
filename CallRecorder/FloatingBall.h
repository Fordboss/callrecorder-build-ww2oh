#import <Foundation/Foundation.h>

@interface FloatingBall : NSObject
+ (instancetype)shared;
- (void)show;              // 显示悬浮球（浮在微信/QQ 之上）
- (void)hide;              // 隐藏
- (void)tapFromBackground; // 供通知按钮间接调用的状态刷新
@property (nonatomic, readonly) BOOL isShown;
@end
