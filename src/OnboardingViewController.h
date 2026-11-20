#import <AppKit/AppKit.h>
#import "BawanPanelPage.h"
#import "SetupPresentation.h"
#include "TranslationEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface OnboardingViewController : NSViewController <BawanPanelPage, BawanModelSetupDisplay>
@property(nonatomic, copy, nullable) void (^onBack)(void);
// Performs the current model action: download, retry, pause or resume.
@property(nonatomic, copy, nullable) void (^onModelSetup)(void);
// Leaves onboarding for the translator from the shortcut step, ready or still downloading.
@property(nonatomic, copy, nullable) void (^onFinish)(void);
@property(nonatomic, copy, nullable) void (^onModelLicense)(void);
@property(nonatomic, copy, nullable) void (^onSelectionTrialInterrupted)(void);
@property(nonatomic, copy, nullable) void (^onSelectionTrialDiscarded)(void);
- (instancetype)initWithPreferences:(ShortcutPreferences *)preferences monitor:(ShortcutMonitor *)monitor;
- (void)setModelPhase:(BawanModelSetupPhase)phase message:(NSString *)message progress:(std::optional<double>)progress;
- (void)setActive:(BOOL)active;
- (void)focusInitialControl;
- (void)refresh;
- (void)showSelectionCopyError:(NSString *)message;
- (void)clearSelectionCopyError;
@property(nonatomic, readonly) NSString *selectionTrialText;
@property(nonatomic, readonly) BOOL selectionTrialComplete;
- (BOOL)beginSelectionTrialForText:(NSString *)text;
- (BOOL)finishSelectionTrialWithOutput:(nullable NSString *)output;
- (void)cancelSelectionTrial;
- (void)discardSelectionTrialResult;
- (void)restoreCompletedSelectionTrial;
@end

NS_ASSUME_NONNULL_END
