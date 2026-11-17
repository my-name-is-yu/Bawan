#import "ShortcutMonitor.h"
#import <CoreGraphics/CoreGraphics.h>

#include <cstdlib>
#include <iostream>

// Exercise the production tap callback's routing without installing system-wide taps.
@interface ShortcutMonitor (EventRoutingTests)
- (BOOL)handleEventType:(CGEventType)type event:(CGEventRef)event active:(BOOL)active;
@end
@interface RoutingMonitor : ShortcutMonitor
@property(nonatomic) ShortcutAvailability trialAvailability;
@end
@implementation RoutingMonitor
- (void)refresh {}
- (ShortcutAvailability)availabilityForAction:(bawan::ShortcutAction)action {
    return action == bawan::ShortcutAction::TranslateSelection ? _trialAvailability :
        [super availabilityForAction:action];
}
@end

static void require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

static bool route(ShortcutMonitor *monitor, CGEventType type, std::uint16_t key,
                  CGEventFlags modifiers, bool active = true, bool repeat = false) {
    static std::uint64_t timestamp = 1'000'000'000;
    CGEventRef event = CGEventCreateKeyboardEvent(nullptr, key, type == kCGEventKeyDown);
    require(event != nullptr, "keyboard event can be created without event-tap permission");
    CGEventSetFlags(event, modifiers);
    CGEventSetTimestamp(event, timestamp += 20'000'000);
    CGEventSetIntegerValueField(event, kCGKeyboardEventAutorepeat, repeat);
    const bool consumed = [monitor handleEventType:type event:event active:active];
    CFRelease(event);
    return consumed;
}

static void settle() {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];
        [NSApp deactivate];
        NSString *suite = [@"local.bawan.ShortcutMonitorTests." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        ShortcutPreferences *preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        RoutingMonitor *monitor = [[RoutingMonitor alloc] initWithPreferences:preferences];
        __block unsigned opens = 0, copies = 0, problems = 0;
        __block NSString *copiedText = nil;
        monitor.onOpenPanel = ^{ ++opens; };
        monitor.onText = ^(NSString *text) { ++copies; copiedText = text; };
        monitor.onProblem = ^(NSString *__unused message) { ++problems; };
        [monitor start];
        NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(100, 100, 300, 200)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskNonactivatingPanel
            backing:NSBackingStoreBuffered defer:NO];
        panel.hidesOnDeactivate = NO;
        panel.becomesKeyOnlyIfNeeded = NO;
        [panel orderFront:nil];
        [panel makeKeyWindow];
        require(NSApp.keyWindow == panel && panel.isKeyWindow && panel.visible,
                "nonactivating panel owns keyboard input");
        // Hosted AppKit may reactivate the app despite deactivate; the key-window
        // boundary is established here, but inactive-app behavior is not.

        struct Command { std::uint16_t key; std::uint8_t modifiers; CGEventFlags flags; };
        const Command commands[] = {{0, bawan::Command, kCGEventFlagMaskCommand},
            {6, bawan::Command, kCGEventFlagMaskCommand}, {7, bawan::Command, kCGEventFlagMaskCommand},
            {8, bawan::Command, kCGEventFlagMaskCommand}, {9, bawan::Command, kCGEventFlagMaskCommand},
            {13, bawan::Command, kCGEventFlagMaskCommand},
            {6, bawan::Command | bawan::Shift, kCGEventFlagMaskCommand | kCGEventFlagMaskShift}};
        auto bind = [&](const Command &command, unsigned presses) {
            require([preferences setBinding:bawan::ShortcutBinding{false, 8, bawan::Command, 2}
                forAction:bawan::ShortcutAction::TranslateSelection error:nil], "disable selection binding");
            require([preferences setBinding:bawan::ShortcutBinding{true, command.key, command.modifiers, static_cast<std::uint8_t>(presses)}
                forAction:bawan::ShortcutAction::OpenPanel error:nil], "configure allowed custom binding");
        };
        for (const auto &command : commands) {
            for (unsigned presses : {1u, 2u}) {
                bind(command, presses);
                for (unsigned press = 0; press < 2; ++press) {
                    require(!route(monitor, kCGEventKeyDown, command.key, command.flags),
                            "every native down reaches the key window, including a double binding's first press");
                    require(!route(monitor, kCGEventKeyUp, command.key, 0), "native release reaches the window");
                }
                settle();
                require(opens == 0, "native commands never dispatch the custom panel action");
            }
        }

        // Settings bypasses even non-native custom bindings, before either press is swallowed.
        bind({17, bawan::Option, kCGEventFlagMaskAlternate}, 2);
        monitor.configurationActive = YES;
        for (unsigned press = 0; press < 2; ++press) {
            require(!route(monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "Settings receives custom downs");
            require(!route(monitor, kCGEventKeyUp, 17, kCGEventFlagMaskAlternate), "Settings receives custom releases");
        }
        settle();
        require(opens == 0, "Settings does not dispatch a global action");
        monitor.configurationActive = NO;
        for (unsigned press = 0; press < 2; ++press) {
            require(route(monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "translator retains Option-T shortcut");
            require(route(monitor, kCGEventKeyUp, 17, kCGEventFlagMaskAlternate), "Option-T release stays paired");
        }
        settle();
        require(opens == 1, "Option-T twice still opens/focuses the visible translator");
        require(route(monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "capture a key before Settings opens");
        monitor.configurationActive = YES;
        require(route(monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate, true, true), "Settings drains an already captured repeat");
        require(route(monitor, kCGEventKeyUp, 17, 0), "Settings drains an already captured release");
        require(!route(monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "Settings receives the next fresh press");
        require(!route(monitor, kCGEventKeyUp, 17, 0), "Settings receives the next fresh release");
        monitor.configurationActive = NO;

        // A captured down must drain through a focus change, then native editing can resume.
        bind({9, bawan::Command, kCGEventFlagMaskCommand}, 2);
        [panel orderOut:nil];
        require(NSApp.keyWindow == nil, "outside-app route has no Bawan key window");
        require(route(monitor, kCGEventKeyDown, 9, kCGEventFlagMaskCommand), "outside app custom first press is intercepted");
        [panel orderFront:nil];
        [panel makeKeyWindow];
        require(route(monitor, kCGEventKeyDown, 9, kCGEventFlagMaskCommand, true, true), "held repeat drains after native focus begins");
        require(route(monitor, kCGEventKeyUp, 9, 0), "captured release drains after modifiers are released");
        require(!route(monitor, kCGEventKeyDown, 9, kCGEventFlagMaskCommand), "fresh Paste reaches the key window");
        require(!route(monitor, kCGEventKeyUp, 9, 0), "fresh Paste release reaches the key window");
        settle();
        require(opens == 1, "focus transition does not complete the outside custom pair");
        [panel orderOut:nil];
        for (unsigned press = 0; press < 2; ++press) {
            require(route(monitor, kCGEventKeyDown, 9, kCGEventFlagMaskCommand), "custom Paste binding remains available outside Bawan");
            require(route(monitor, kCGEventKeyUp, 9, kCGEventFlagMaskCommand), "outside custom release stays paired");
        }
        settle();
        require(opens == 2, "native priority does not disable a legitimate custom binding outside Bawan");

        // The same native boundary applies to custom selection translation, including single Copy.
        [panel orderFront:nil];
        [panel makeKeyWindow];
        require([preferences restoreAction:bawan::ShortcutAction::OpenPanel error:nil] &&
                [preferences setBinding:bawan::ShortcutBinding{true, 8, bawan::Command, 1}
                    forAction:bawan::ShortcutAction::TranslateSelection error:nil], "configure custom selection Copy");
        require(!route(monitor, kCGEventKeyDown, 8, kCGEventFlagMaskCommand), "custom selection binding cannot intercept native Copy");
        require(!route(monitor, kCGEventKeyUp, 8, 0), "native Copy release is preserved");

        // Only the focused, fully selected onboarding sample may use selection shortcuts
        // during configuration. The production recognizer handles both passive and custom bindings.
        require(copies == 0 && problems == 0, "native routing has not copied text or reported errors");
        NSTextView *sample = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 280, 150)];
        sample.string = @"Try translating this sentence.";
        sample.editable = NO;
        sample.selectable = YES;
        panel.contentView = sample;
        [panel makeKeyWindow];
        require([panel makeFirstResponder:sample], "the selectable trial can own keyboard focus");
        sample.selectedRange = NSMakeRange(0, sample.string.length);
        monitor.configurationActive = YES;
        monitor.selectionTrialView = sample;
        monitor.trialAvailability = ShortcutAvailabilityAvailable;
        require([preferences restoreAction:bawan::ShortcutAction::TranslateSelection error:nil], "restore the passive trial binding");
        auto copyPress = [&] {
            require(!route(monitor, kCGEventKeyDown, 8, kCGEventFlagMaskCommand), "trial Copy reaches the native responder through the active tap");
            require(!route(monitor, kCGEventKeyDown, 8, kCGEventFlagMaskCommand, false), "trial Copy stays passive");
            require(!route(monitor, kCGEventKeyUp, 8, 0), "trial Copy release reaches the native responder");
            require(!route(monitor, kCGEventKeyUp, 8, 0, false), "trial Copy release stays passive");
        };
        copyPress();
        settle();
        require(copies == 0, "selecting text and one Copy do not finish a double-press trial");
        monitor.selectionTrialView = sample;
        copyPress();
        settle();
        require(copies == 1 && [copiedText isEqualToString:sample.string],
                "the passive trial delivers the selected sample without requiring clipboard changes");
        const unsigned trialOpens = opens;
        for (unsigned press = 0; press < 2; ++press) {
            require(!route(monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "configuration still receives the panel shortcut down");
            require(!route(monitor, kCGEventKeyUp, 17, kCGEventFlagMaskAlternate), "configuration still receives the panel shortcut release");
        }
        settle();
        require(opens == trialOpens && copies == 1, "the trial scope never opens the panel action");

        for (unsigned presses : {1u, 2u}) {
            require([preferences setBinding:bawan::ShortcutBinding{true, 15, bawan::Option, static_cast<std::uint8_t>(presses)}
                forAction:bawan::ShortcutAction::TranslateSelection error:nil], "configure a custom trial binding");
            for (unsigned press = 0; press < presses; ++press) {
                require(route(monitor, kCGEventKeyDown, 15, kCGEventFlagMaskAlternate), "the selected sample recognizes its custom binding");
                require(route(monitor, kCGEventKeyUp, 15, kCGEventFlagMaskAlternate), "the selected sample drains the custom release");
            }
            settle();
            require(copies == presses + 1 && [copiedText isEqualToString:sample.string],
                    "a current custom once/twice binding delivers exactly the sample");
        }
        require([preferences setBinding:bawan::ShortcutBinding{true, 8, bawan::Command, 1}
            forAction:bawan::ShortcutAction::TranslateSelection error:nil], "configure native Copy as a single trial binding");
        auto customCopyPress = [&](bool consumed) {
            require(route(monitor, kCGEventKeyDown, 8, kCGEventFlagMaskCommand) == consumed, "native custom Copy obeys the trial scope");
            require(route(monitor, kCGEventKeyUp, 8, 0) == consumed, "native custom Copy release stays paired");
        };
        customCopyPress(true);
        settle();
        require(copies == 4, "a native custom binding is available only for the selected trial");

        sample.selectedRange = NSMakeRange(0, 3);
        customCopyPress(false);
        sample.selectedRange = NSMakeRange(0, 0);
        customCopyPress(false);
        sample.selectedRange = NSMakeRange(0, sample.string.length);
        monitor.trialAvailability = ShortcutAvailabilityNeedsAccessibility;
        customCopyPress(false);
        monitor.trialAvailability = ShortcutAvailabilityAvailable;
        [panel makeFirstResponder:nil];
        require(panel.firstResponder != sample, "the invalid-scope fixture leaves sample focus");
        customCopyPress(false);
        [panel makeFirstResponder:sample];
        sample.selectedRange = NSMakeRange(0, sample.string.length);
        customCopyPress(true);
        monitor.selectionTrialView = nil;
        settle();
        require(copies == 4, "partial/empty selection, missing permission, focus changes and leaving the trial cannot deliver a sample");
        monitor.selectionTrialView = sample;
        customCopyPress(true);
        sample.selectedRange = NSMakeRange(0, 3);
        settle();
        require(copies == 4, "selection changes after a recognized shortcut invalidate asynchronous delivery");
        sample.selectedRange = NSMakeRange(0, sample.string.length);
        customCopyPress(true);
        sample.string = @"The sample changed before delivery.";
        sample.selectedRange = NSMakeRange(0, sample.string.length);
        settle();
        require(copies == 4, "changed sample text cannot inherit a previous recognized shortcut");
        customCopyPress(true);
        monitor.trialAvailability = ShortcutAvailabilityNeedsAccessibility;
        settle();
        require(copies == 4, "permission loss before delivery invalidates a recognized shortcut");
        monitor.trialAvailability = ShortcutAvailabilityAvailable;
        customCopyPress(true);
        require([preferences restoreAction:bawan::ShortcutAction::TranslateSelection error:nil], "change a binding before trial delivery");
        settle();
        require(copies == 4, "binding changes invalidate a recognized shortcut before delivery");
        monitor.selectionTrialView = nil;
        monitor.configurationActive = NO;

        // Default Cmd-C remains a passive observer outside Bawan.
        [panel orderOut:nil];
        require([preferences restoreAction:bawan::ShortcutAction::OpenPanel error:nil] &&
                [preferences restoreAction:bawan::ShortcutAction::TranslateSelection error:nil], "restore defaults");
        for (unsigned press = 0; press < 2; ++press) {
            require(!route(monitor, kCGEventKeyDown, 8, kCGEventFlagMaskCommand, false), "default copy down stays passive");
            require(!route(monitor, kCGEventKeyUp, 8, 0, false), "default copy release stays passive");
        }
        [monitor stop];
        [panel close];
        [defaults removePersistentDomainForName:suite];
        require(copies == 4 && problems == 0, "only valid local trials delivered text; routing did not synthesize a copy or report errors");
        std::cout << "Shortcut monitor native routing tests passed\n";
    }
}
