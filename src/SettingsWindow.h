#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>

NS_ASSUME_NONNULL_BEGIN

@interface SettingsWindow : NSWindowController
@property(nonatomic, copy, nullable) void (^onInputMonitoring)(void);
@property(nonatomic, copy, nullable) void (^onLoginSettings)(void);
@property(nonatomic, copy, nullable) void (^onLoginChanged)(BOOL enabled);
- (void)setShortcutAvailable:(BOOL)available permissionGranted:(BOOL)granted;
- (void)setLoginStatus:(SMAppServiceStatus)status message:(nullable NSString *)message error:(BOOL)error;
@end

NS_ASSUME_NONNULL_END
