#import "BawanAppearance.h"
#import "ShortcutMonitor.h"

typedef NS_ENUM(NSInteger, BawanModelSetupPhase) {
    BawanModelSetupNeedsDownload,
    BawanModelSetupPreparing,
    BawanModelSetupReady,
    BawanModelSetupFailed
};

@protocol BawanModelSetupDisplay <NSObject>
- (void)setModelPhase:(BawanModelSetupPhase)phase message:(NSString *)message progress:(double)progress;
@end

// Copy and color for the model's setup phase, shared by onboarding and Settings.
struct BawanModelPresentation {
    NSString *status;
    BawanColorRole statusColor;
    NSString *symbol;
    BawanColorRole symbolColor;
    NSString *actionTitle;  // The setup or retry action; unused while preparing or ready.
};

inline BawanModelPresentation BawanPresentModel(BawanModelSetupPhase phase) {
    switch (phase) {
        case BawanModelSetupNeedsDownload:
            return {@"Not set up", BawanSecondaryText, @"arrow.down.circle", BawanSecondaryText,
                @"Review License & Download"};
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
