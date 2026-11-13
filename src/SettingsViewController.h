#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import "ShortcutMonitor.h"

NS_ASSUME_NONNULL_BEGIN

@interface SettingsViewController : NSViewController
@property(nonatomic, copy, nullable) void (^onBack)(void);
@property(nonatomic, copy, nullable) void (^onLoginSettings)(void);
@property(nonatomic, copy, nullable) void (^onLoginChanged)(BOOL enabled);
- (instancetype)initWithPreferences:(ShortcutPreferences *)preferences monitor:(ShortcutMonitor *)monitor;
// The host owns window focus; active means this screen is visible and key.
- (void)setActive:(BOOL)active;
- (void)focusInitialControl;
- (void)refresh;
- (void)showError:(NSString *)message;
- (void)setLoginStatus:(SMAppServiceStatus)status message:(nullable NSString *)message error:(BOOL)error;
@end

NS_ASSUME_NONNULL_END
