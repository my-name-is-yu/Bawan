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
            return {@"Shortcut ready", @"Set up…", @"", BawanSuccess, false};
        case ShortcutAvailabilityNeedsInputMonitoring:
            return {@"Input Monitoring required", @"Set up…", @"Opens Input Monitoring in System Settings.",
                BawanWarning, true};
        case ShortcutAvailabilityNeedsAccessibility:
            return {@"Accessibility required", @"Set up…", @"Opens Accessibility in System Settings.",
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
