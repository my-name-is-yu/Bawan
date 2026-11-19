#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol BawanPanelPage <NSObject>
@property(nonatomic, copy, nullable) void (^onBack)(void);
- (void)setActive:(BOOL)active;
- (void)focusInitialControl;
- (void)refresh;
// The page's footer primary action, also bound to ⌘Return like the translator's.
- (void)performPrimaryAction;
@optional
- (void)willLeavePanelPage;
@end

NS_ASSUME_NONNULL_END
