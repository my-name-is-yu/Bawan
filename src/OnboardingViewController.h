#import <AppKit/AppKit.h>
#import "BawanPanelPage.h"
#import "SetupPresentation.h"

NS_ASSUME_NONNULL_BEGIN

@interface OnboardingViewController : NSViewController <BawanPanelPage, BawanModelSetupDisplay>
@property(nonatomic, copy, nullable) void (^onBack)(void);
@property(nonatomic, copy, nullable) void (^onModelSetup)(void);
// Leaves onboarding for the translator from the shortcut step, ready or still downloading.
@property(nonatomic, copy, nullable) void (^onFinish)(void);
@property(nonatomic, copy, nullable) void (^onModelLicense)(void);
- (instancetype)initWithPreferences:(ShortcutPreferences *)preferences monitor:(ShortcutMonitor *)monitor;
- (void)setModelPhase:(BawanModelSetupPhase)phase message:(NSString *)message progress:(std::optional<double>)progress;
- (void)setActive:(BOOL)active;
- (void)focusInitialControl;
- (void)refresh;
@end

NS_ASSUME_NONNULL_END
