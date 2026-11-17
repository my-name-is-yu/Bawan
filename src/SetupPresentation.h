#import "BawanAppearance.h"
#import "ModelSetupState.h"
#import "ShortcutMonitor.h"

@protocol BawanModelSetupDisplay <NSObject>
- (void)setModelPhase:(BawanModelSetupPhase)phase message:(NSString *)message progress:(double)progress;
@end

// Copy and color for the model's setup phase, shared by onboarding and Settings.
struct BawanModelPresentation {
    NSString *status;
    BawanColorRole statusColor;
    NSString *symbol;
    BawanColorRole symbolColor;
    NSString *actionTitle;
};

inline BawanModelPresentation BawanPresentModel(BawanModelSetupPhase phase) {
    switch (phase) {
        case BawanModelSetupNeedsDownload:
            return {@"Not set up", BawanSecondaryText, @"arrow.down.circle", BawanSecondaryText,
                @"Download Model…"};
        case BawanModelSetupDownloading:
            return {@"Downloading…", BawanSecondaryText, @"arrow.down.circle", BawanSecondaryText, @"Pause Download"};
        case BawanModelSetupPaused:
            return {@"Paused", BawanSecondaryText, @"pause.circle", BawanSecondaryText, @"Resume Download"};
        case BawanModelSetupResumableFailure:
            return {@"Needs attention", BawanError, @"exclamationmark.circle", BawanError, @"Resume Download"};
        case BawanModelSetupPreparing:
            return {@"Preparing…", BawanSecondaryText, @"arrow.down.circle", BawanSecondaryText, @""};
        case BawanModelSetupReady:
            return {@"Ready", BawanSuccess, @"checkmark.circle.fill", BawanSuccess, @""};
        case BawanModelSetupFailed:
            break;
    }
    return {@"Needs attention", BawanError, @"exclamationmark.circle", BawanError, @"Retry Model Setup"};
}

static NSString *const BawanModelLicenseTitle = @"Model License";

// The global shortcuts in display order, shared by onboarding and Settings.
static constexpr bawan::ShortcutAction BawanShortcutActions[] = {
    bawan::ShortcutAction::TranslateSelection, bawan::ShortcutAction::OpenPanel
};

// The stable slug used in control identifiers.
inline NSString *ShortcutSlug(bawan::ShortcutAction action) {
    return action == bawan::ShortcutAction::TranslateSelection ? @"selection" : @"panel";
}

inline NSString *ShortcutPressCountTitle(unsigned pressCount) { return pressCount == 1 ? @"Once" : @"Twice"; }

struct BawanShortcutPresentation {
    NSString *status;
    NSString *actionTitle;  // Visible button title; short enough for the Settings cards.
    NSString *actionHelp;   // Spoken detail for what the button opens.
    BawanColorRole color;
    bool needsAction;       // A permission or retry is required while the shortcut is enabled.
};

inline BawanShortcutPresentation BawanPresentShortcut(ShortcutAvailability availability) {
    switch (availability) {
        case ShortcutAvailabilityOff:
            return {@"Off", @"Enable…", @"Turns on the shortcut and asks for any permission it needs.",
                BawanSecondaryText, false};
        case ShortcutAvailabilityAvailable:
            return {@"Shortcut ready", @"Set Up…", @"", BawanSuccess, false};
        case ShortcutAvailabilityNeedsInputMonitoring:
            return {@"Input Monitoring required", @"Set Up…", @"Opens Input Monitoring in System Settings.",
                BawanWarning, true};
        case ShortcutAvailabilityNeedsAccessibility:
            return {@"Accessibility required", @"Set Up…", @"Opens Accessibility in System Settings.",
                BawanWarning, true};
        case ShortcutAvailabilityFailed:
            break;
    }
    return {@"Could not start monitoring", @"Retry", @"Tries to start shortcut monitoring again.", BawanError, true};
}

inline void BawanApplyShortcutAction(NSButton *button, const BawanShortcutPresentation &presentation,
                                     NSString *actionName) {
    button.title = presentation.actionTitle;
    [button setAccessibilityLabel:[presentation.actionTitle stringByAppendingFormat:@" for %@", actionName]];
    [button setAccessibilityHelp:presentation.actionHelp.length ? presentation.actionHelp : nil];
}
