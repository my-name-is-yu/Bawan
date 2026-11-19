#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import "ShortcutMonitor.h"
#import "BawanPanelPage.h"
#import "SetupPresentation.h"

NS_ASSUME_NONNULL_BEGIN

@interface SettingsViewController : NSViewController <BawanPanelPage, BawanModelSetupDisplay>
@property(nonatomic, copy, nullable) void (^onBack)(void);
@property(nonatomic, copy, nullable) void (^onLoginSettings)(void);
@property(nonatomic, copy, nullable) void (^onLoginChanged)(BOOL enabled);
@property(nonatomic, copy, nullable) void (^onModelLicense)(void);
// Performs the current model action: download, retry, pause or resume.
@property(nonatomic, copy, nullable) void (^onModelSetup)(void);
@property(nonatomic, readonly) BOOL recordingShortcut;
- (instancetype)initWithPreferences:(ShortcutPreferences *)preferences monitor:(ShortcutMonitor *)monitor;
// The host owns window focus; active means this screen is visible and key.
- (void)setActive:(BOOL)active;
- (void)focusInitialControl;
- (void)refresh;
- (void)showError:(NSString *)message;
- (void)setLoginStatus:(SMAppServiceStatus)status message:(nullable NSString *)message error:(BOOL)error;
- (void)setModelPhase:(BawanModelSetupPhase)phase message:(NSString *)message progress:(std::optional<double>)progress;
@end

NS_ASSUME_NONNULL_END
