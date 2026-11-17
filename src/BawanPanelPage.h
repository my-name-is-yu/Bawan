#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol BawanPanelPage <NSObject>
@property(nonatomic, copy, nullable) void (^onBack)(void);
- (void)setActive:(BOOL)active;
- (void)focusInitialControl;
- (void)refresh;
@end

NS_ASSUME_NONNULL_END
