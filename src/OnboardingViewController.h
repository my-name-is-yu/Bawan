#import <AppKit/AppKit.h>
#import "BawanPanelPage.h"
#import "SetupPresentation.h"
#include "TranslationEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface OnboardingViewController : NSViewController <BawanPanelPage, BawanModelSetupDisplay>
@property(nonatomic, copy, nullable) void (^onBack)(void);
@property(nonatomic, copy, nullable) void (^onModelSetup)(void);
// Leaves onboarding for the translator from the shortcut step, ready or still downloading.
@property(nonatomic, copy, nullable) void (^onFinish)(void);
@property(nonatomic, copy, nullable) void (^onModelLicense)(void);
- (instancetype)initWithPreferences:(ShortcutPreferences *)preferences monitor:(ShortcutMonitor *)monitor;
- (void)setModelPhase:(BawanModelSetupPhase)phase message:(NSString *)message progress:(double)progress;
- (void)setActive:(BOOL)active;
- (void)focusInitialControl;
- (void)refresh;
@property(nonatomic, readonly) NSString *selectionTrialText;
@property(nonatomic, readonly, nullable) NSString *selectionTrialOutput;
@property(nonatomic, readonly) bawan::Direction selectionTrialDirection;
@property(nonatomic, readonly) BOOL selectionTrialComplete;
// Only the real selection callback may begin a trial; selection or setup alone cannot finish it.
- (BOOL)isSelectionTrialText:(NSString *)text;
- (NSUInteger)beginSelectionTrial;
- (BOOL)isSelectionTrialCurrent:(NSUInteger)attempt;
- (BOOL)finishSelectionTrial:(NSUInteger)attempt output:(nullable NSString *)output
                  direction:(bawan::Direction)direction;
- (void)cancelSelectionTrial;
@end

NS_ASSUME_NONNULL_END
