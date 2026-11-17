#import "BawanAppearance.h"
#import "ShortcutMonitor.h"

typedef NS_ENUM(NSInteger, BawanModelSetupPhase) {
    BawanModelSetupNeedsDownload,
    BawanModelSetupPreparing,
    BawanModelSetupReady,
    BawanModelSetupFailed
};

struct BawanShortcutPresentation {
    NSString *status;
    NSString *actionTitle;
    BawanColorRole color;
    bool needsAction;
};

inline BawanShortcutPresentation BawanPresentShortcut(ShortcutAvailability availability) {
    switch (availability) {
        case ShortcutAvailabilityOff:
            return {@"Off", @"Set up…", BawanSecondaryText, false};
        case ShortcutAvailabilityAvailable:
            return {@"Shortcut ready", @"Set up…", BawanSuccess, false};
        case ShortcutAvailabilityNeedsInputMonitoring:
            return {@"Input Monitoring required", @"Open Input Monitoring…", BawanWarning, true};
        case ShortcutAvailabilityNeedsAccessibility:
            return {@"Accessibility required", @"Open Accessibility…", BawanWarning, true};
        case ShortcutAvailabilityFailed:
            return {@"Could not start monitoring", @"Retry", BawanError, true};
    }
    return {@"Could not start monitoring", @"Retry", BawanError, true};
}
