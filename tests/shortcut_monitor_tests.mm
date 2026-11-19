#import "ShortcutMonitor.h"
#import "ShortcutMonitor+Testing.h"
#import "SelectionReader.h"
#import <CoreGraphics/CoreGraphics.h>

#include <cstdlib>
#include <iostream>

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

@interface RoutingSelectionReader : SelectionReader
@property(nonatomic) unsigned begins;
@property(nonatomic) unsigned reads;
@property(nonatomic) unsigned cancellations;
@property(nonatomic) BOOL lastPassive;
@end
@implementation RoutingSelectionReader
- (void)beginCopyFromApplication:(pid_t)application passive:(BOOL)passive {
    (void)application;
    ++_begins;
    _lastPassive = passive;
}
- (void)readSelection { ++_reads; }
- (void)cancel { ++_cancellations; }
@end

@interface RoutingActions : NSObject
@property(nonatomic) unsigned opens;
@end
@implementation RoutingActions
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

struct RoutingFixture {
    NSString *suite;
    NSUserDefaults *defaults;
    ShortcutPreferences *preferences;
    RoutingSelectionReader *reader;
    RoutingMonitor *monitor;
    RoutingActions *actions;

    RoutingFixture() {
        suite = [@"local.bawan.ShortcutMonitorTests." stringByAppendingString:NSUUID.UUID.UUIDString];
        defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        reader = [RoutingSelectionReader new];
        monitor = [[RoutingMonitor alloc] initWithPreferences:preferences selectionReader:reader];
        actions = [RoutingActions new];
        RoutingActions *counts = actions;
        monitor.onOpenPanel = ^{ ++counts.opens; };
        [monitor start];
    }
    ~RoutingFixture() {
        [monitor stop];
        [defaults removePersistentDomainForName:suite];
    }
    void bind(bawan::ShortcutAction action, bawan::ShortcutBinding binding) {
        require([preferences setBinding:binding forAction:action error:nil], "configure routing-test binding");
    }
    void open(unsigned presses = 1, std::uint16_t key = 17, std::uint8_t modifiers = bawan::Option) {
        bind(bawan::ShortcutAction::TranslateSelection, {false, 8, bawan::Command, 2});
        bind(bawan::ShortcutAction::OpenPanel, {true, key, modifiers, static_cast<std::uint8_t>(presses)});
    }
    void selection(unsigned presses = 1) {
        bind(bawan::ShortcutAction::OpenPanel, {false, 17, bawan::Option, 2});
        bind(bawan::ShortcutAction::TranslateSelection, {true, 8, bawan::Command, static_cast<std::uint8_t>(presses)});
    }
};

static void postWorkspaceNotification(NSNotificationName name) {
    [NSWorkspace.sharedWorkspace.notificationCenter postNotificationName:name object:nil];
}

static void testSelectionCallbacks() {
    RoutingFixture fixture;
    if (fixture.reader.onResult) fixture.reader.onResult([[SelectionResult alloc] initWithKind:SelectionResultKindText text:@"No listener"]);
    if (fixture.reader.onResult) fixture.reader.onResult([[SelectionResult alloc] initWithKind:SelectionResultKindProblem text:@"No listener"]);
    __block NSString *selectedText;
    __block NSString *problem;
    fixture.monitor.onSelection = ^(SelectionResult *result) {
        require(NSThread.isMainThread, "selection callback runs on the main thread");
        if (result.kind == SelectionResultKindText) selectedText = result.text;
        else if (result.kind == SelectionResultKindProblem) problem = result.text;
    };
    fixture.reader.onResult([[SelectionResult alloc] initWithKind:SelectionResultKindText text:@"Selected sentence"]);
    fixture.reader.onResult([[SelectionResult alloc] initWithKind:SelectionResultKindProblem text:@"Copy failed"]);
    require([selectedText isEqualToString:@"Selected sentence"], "reader text reaches the monitor callback");
    require([problem isEqualToString:@"Copy failed"], "reader problem reaches the monitor callback");
    fixture.reader.onResult([[SelectionResult alloc] initWithKind:SelectionResultKindText text:@""]);
    fixture.reader.onResult([[SelectionResult alloc] initWithKind:SelectionResultKindProblem text:@""]);
    require([selectedText isEqualToString:@""] && [problem isEqualToString:@""], "callbacks preserve empty payloads");
    fixture.monitor.onSelection = nil;
    if (fixture.reader.onResult) fixture.reader.onResult([[SelectionResult alloc] initWithKind:SelectionResultKindText text:@"No listener"]);
    if (fixture.reader.onResult) fixture.reader.onResult([[SelectionResult alloc] initWithKind:SelectionResultKindProblem text:@"No listener"]);
}

static void testHeldKeyReconfiguration() {
    RoutingFixture fixture;
    fixture.open(2);
    require(route(fixture.monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "capture old binding before reconfiguration");
    fixture.open(1, 40, bawan::Control | bawan::Option);
    require(route(fixture.monitor, kCGEventKeyDown, 17, 0, true, true), "rebound key retains ownership of its held repeat");
    settle();
    require(fixture.actions.opens == 0, "old held key cannot trigger the replacement binding");
    require(route(fixture.monitor, kCGEventKeyUp, 17, 0), "rebound key release is still swallowed");
    require(!route(fixture.monitor, kCGEventKeyUp, 17, 0), "old key release is owned exactly once");
    require(route(fixture.monitor, kCGEventKeyDown, 40, kCGEventFlagMaskControl | kCGEventFlagMaskAlternate), "replacement chord is available");
    require(route(fixture.monitor, kCGEventKeyUp, 40, 0), "replacement chord owns its release");
    settle();
    require(fixture.actions.opens == 1, "replacement binding dispatches its own action");

    fixture.open(2);
    require(route(fixture.monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "capture double binding before changing press count");
    fixture.open(1);
    require(route(fixture.monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate, true, true), "same-key reconfiguration drains old repeats");
    require(route(fixture.monitor, kCGEventKeyUp, 17, 0), "same-key reconfiguration drains old release");
    settle();
    require(fixture.actions.opens == 1, "held double press does not become a new single trigger");
    require(route(fixture.monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "new single binding accepts a fresh press");
    fixture.bind(bawan::ShortcutAction::OpenPanel, {false, 17, bawan::Option, 1});
    require(route(fixture.monitor, kCGEventKeyDown, 17, 0, true, true), "disabled binding still drains captured repeats");
    require(route(fixture.monitor, kCGEventKeyUp, 17, 0), "disabled binding still drains captured release");
    require(!route(fixture.monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "disabled binding passes the next press through");
    require(!route(fixture.monitor, kCGEventKeyUp, 17, 0), "disabled binding passes the next release through");
    settle();
    require(fixture.actions.opens == 1, "disabling a binding cancels its queued action");

    fixture.selection();
    require(route(fixture.monitor, kCGEventKeyDown, 8, kCGEventFlagMaskCommand), "single Copy is intercepted before becoming passive");
    require(fixture.reader.begins == 1 && !fixture.reader.lastPassive && fixture.reader.reads == 0,
            "active selection waits for the physical release");
    fixture.selection(2);
    require(route(fixture.monitor, kCGEventKeyDown, 8, 0, true, true), "active-to-passive change drains the intercepted repeat");
    require(route(fixture.monitor, kCGEventKeyUp, 8, 0), "active-to-passive change drains the intercepted release");
    require(fixture.reader.reads == 0, "reconfiguration cannot read the old active selection");
    for (unsigned press = 0; press < 2; ++press) {
        require(!route(fixture.monitor, kCGEventKeyDown, 8, kCGEventFlagMaskCommand, false), "new passive Copy down reaches the source app");
        require(!route(fixture.monitor, kCGEventKeyUp, 8, 0, false), "new passive Copy release reaches the source app");
    }
    require(fixture.reader.begins == 2 && fixture.reader.lastPassive && fixture.reader.reads == 1,
            "fresh passive pair uses its own selection read");
    require(!route(fixture.monitor, kCGEventKeyDown, 8, kCGEventFlagMaskCommand, false), "passive press reaches the source before changing to active");
    fixture.selection();
    require(!route(fixture.monitor, kCGEventKeyDown, 8, kCGEventFlagMaskCommand, true, true),
            "passive-to-active change cannot capture a repeat whose down reached the source");
    require(!route(fixture.monitor, kCGEventKeyUp, 8, 0), "previously passive release still reaches the source");
    require(fixture.reader.reads == 1, "passive-to-active change cancels the unfinished passive pair");
    require(route(fixture.monitor, kCGEventKeyDown, 8, kCGEventFlagMaskCommand), "new active Copy captures a fresh down");
    require(route(fixture.monitor, kCGEventKeyUp, 8, 0), "new active Copy captures its own release");
    require(fixture.reader.begins == 4 && !fixture.reader.lastPassive && fixture.reader.reads == 2,
            "fresh active Copy works after passive-to-active reconfiguration");
}

static void testIndependentModes() {
    RoutingFixture fixture;
    fixture.open();
    fixture.monitor.suspended = YES;
    fixture.monitor.configurationActive = YES;
    [fixture.monitor stop];
    [fixture.monitor start];
    require(fixture.monitor.suspended && fixture.monitor.configurationActive, "stop/start preserves both user-controlled gates");
    require(!route(fixture.monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "restarting while suspended and recording passes input through");
    require(!route(fixture.monitor, kCGEventKeyUp, 17, 0), "restarting while gated passes releases through");
    fixture.monitor.suspended = NO;
    require(!route(fixture.monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "resuming suspension does not exit recording");
    require(!route(fixture.monitor, kCGEventKeyUp, 17, 0), "recording keeps the corresponding release");
    fixture.monitor.configurationActive = NO;
    require(route(fixture.monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "clearing both gates resumes monitoring");
    require(route(fixture.monitor, kCGEventKeyUp, 17, 0), "resumed monitoring owns the release");
    settle();
    require(fixture.actions.opens == 1, "restart retains the configured shortcut");

    fixture.monitor.suspended = YES;
    fixture.monitor.configurationActive = YES;
    postWorkspaceNotification(NSWorkspaceWillSleepNotification);
    fixture.monitor.configurationActive = NO;
    postWorkspaceNotification(NSWorkspaceDidWakeNotification);
    require(fixture.monitor.suspended, "waking preserves suspension after recording ends during sleep");
    require(!route(fixture.monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "wake does not resume a suspended monitor");
    require(!route(fixture.monitor, kCGEventKeyUp, 17, 0), "suspended wake passes releases through");
    postWorkspaceNotification(NSWorkspaceWillSleepNotification);
    fixture.monitor.suspended = NO;
    require(!route(fixture.monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "resuming suspension does not wake the monitor");
    fixture.monitor.configurationActive = YES;
    postWorkspaceNotification(NSWorkspaceDidWakeNotification);
    require(fixture.monitor.configurationActive, "wake preserves recording started during sleep");
    require(!route(fixture.monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "recording continues to bypass gestures after wake");
    require(!route(fixture.monitor, kCGEventKeyUp, 17, 0), "recording after wake keeps releases");
    fixture.monitor.configurationActive = NO;
    require(route(fixture.monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "wake and clearing the final gate resume monitoring");
    require(route(fixture.monitor, kCGEventKeyUp, 17, 0), "wake recovery owns the fresh release");
    settle();
    require(fixture.actions.opens == 2, "independent sleep and recording transitions recover");

    fixture.open(2);
    require(route(fixture.monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "capture prefix before overlapping recording and suspension");
    fixture.monitor.configurationActive = YES;
    fixture.monitor.suspended = YES;
    fixture.monitor.configurationActive = NO;
    require(route(fixture.monitor, kCGEventKeyDown, 17, 0, true, true), "suspension drains held repeats after recording ends");
    require(route(fixture.monitor, kCGEventKeyUp, 17, 0), "suspension drains the held release");
    fixture.monitor.suspended = NO;
    require(route(fixture.monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "resume starts a fresh double pair");
    require(route(fixture.monitor, kCGEventKeyUp, 17, kCGEventFlagMaskAlternate), "fresh first release stays paired");
    settle();
    require(fixture.actions.opens == 2, "old prefix cannot survive overlapping gates");
    require(route(fixture.monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "fresh second press completes the resumed pair");
    require(route(fixture.monitor, kCGEventKeyUp, 17, 0), "fresh second release stays paired");
    settle();
    require(fixture.actions.opens == 3, "resumed double binding still triggers");
}

enum class RoutingInterruption { Recording, Suspension, Sleep, Stop };

static void interrupt(RoutingFixture &fixture, RoutingInterruption interruption) {
    switch (interruption) {
        case RoutingInterruption::Recording: fixture.monitor.configurationActive = YES; break;
        case RoutingInterruption::Suspension: fixture.monitor.suspended = YES; break;
        case RoutingInterruption::Sleep: postWorkspaceNotification(NSWorkspaceWillSleepNotification); break;
        case RoutingInterruption::Stop: [fixture.monitor stop]; break;
    }
}

static void resume(RoutingFixture &fixture, RoutingInterruption interruption) {
    switch (interruption) {
        case RoutingInterruption::Recording: fixture.monitor.configurationActive = NO; break;
        case RoutingInterruption::Suspension: fixture.monitor.suspended = NO; break;
        case RoutingInterruption::Sleep: postWorkspaceNotification(NSWorkspaceDidWakeNotification); break;
        case RoutingInterruption::Stop: [fixture.monitor start]; break;
    }
}

static void testCancellationAndRecovery() {
    for (auto interruption : {RoutingInterruption::Recording, RoutingInterruption::Suspension,
                              RoutingInterruption::Sleep, RoutingInterruption::Stop}) {
        RoutingFixture fixture;
        fixture.open();
        require(route(fixture.monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "single trigger queues the panel action");
        require(route(fixture.monitor, kCGEventKeyUp, 17, 0), "queued panel action retains normal release ownership");
        interrupt(fixture, interruption);
        resume(fixture, interruption);
        settle();
        require(fixture.actions.opens == 0, "mode transitions cancel queued panel actions even after immediate resume");
        require(route(fixture.monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "panel binding recovers after cancellation");
        require(route(fixture.monitor, kCGEventKeyUp, 17, 0), "recovered panel binding owns its release");
        settle();
        require(fixture.actions.opens == 1, "fresh panel trigger dispatches after recovery");

        fixture.selection();
        require(route(fixture.monitor, kCGEventKeyDown, 8, kCGEventFlagMaskCommand), "active selection begins before cancellation");
        const unsigned cancellations = fixture.reader.cancellations;
        interrupt(fixture, interruption);
        require(fixture.reader.cancellations > cancellations, "every mode interruption cancels the selection session");
        const bool retainsRelease = interruption == RoutingInterruption::Recording || interruption == RoutingInterruption::Suspension;
        require(route(fixture.monitor, kCGEventKeyUp, 8, 0) == retainsRelease,
                "recording/suspension drain releases; sleep/stop clear physical ownership");
        require(fixture.reader.reads == 0, "cancelled active selection does not read on its old release");
        resume(fixture, interruption);
        require(route(fixture.monitor, kCGEventKeyDown, 8, kCGEventFlagMaskCommand), "active selection recovers after cancellation");
        require(route(fixture.monitor, kCGEventKeyUp, 8, 0), "recovered active selection owns release");
        require(fixture.reader.reads == 1, "fresh active selection reads on its own release");
    }
}

static void testRepeatedTriggersAndDeferredCopy() {
    for (unsigned presses : {1u, 2u}) {
        RoutingFixture fixture;
        fixture.open(presses);
        for (unsigned cycle = 0; cycle < 3; ++cycle) {
            for (unsigned press = 0; press < presses; ++press) {
                require(route(fixture.monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "fresh repeated gesture captures its down");
                if (press + 1 == presses) {
                    require(route(fixture.monitor, kCGEventKeyDown, 17, 0, true, true), "held trigger repeat remains swallowed");
                }
                require(route(fixture.monitor, kCGEventKeyUp, 17, press + 1 == presses ? 0 : kCGEventFlagMaskAlternate),
                        "fresh repeated gesture captures its release");
            }
            settle();
            require(fixture.actions.opens == cycle + 1, "each complete gesture dispatches once across repeated cycles");
        }
        fixture.selection(presses);
        if (presses == 2) {
            // Use an active custom double binding rather than passive Cmd-C.
            fixture.bind(bawan::ShortcutAction::TranslateSelection, {true, 40, bawan::Control | bawan::Option, 2});
        }
        const std::uint16_t key = presses == 1 ? 8 : 40;
        const CGEventFlags flags = presses == 1 ? kCGEventFlagMaskCommand : kCGEventFlagMaskControl | kCGEventFlagMaskAlternate;
        for (unsigned cycle = 0; cycle < 2; ++cycle) {
            for (unsigned press = 0; press < presses; ++press) {
                require(route(fixture.monitor, kCGEventKeyDown, key, flags), "active copy gesture intercepts its press");
                if (press + 1 == presses) {
                    require(fixture.reader.begins == cycle + 1 && !fixture.reader.lastPassive,
                            "each active trigger begins one copy session");
                    require(fixture.reader.reads == cycle, "active trigger defers copying while the key is held");
                    require(route(fixture.monitor, kCGEventKeyDown, key, flags, true, true), "active-copy repeat stays swallowed");
                    require(!route(fixture.monitor, kCGEventKeyUp, 0, 0), "unrelated release is not swallowed");
                    require(fixture.reader.reads == cycle, "repeat and unrelated release do not initiate copying");
                }
                require(route(fixture.monitor, kCGEventKeyUp, key, press + 1 == presses ? 0 : flags),
                        "active copy owns the matching release");
            }
            require(fixture.reader.reads == cycle + 1, "matching release initiates exactly one deferred copy");
            require(!route(fixture.monitor, kCGEventKeyUp, key, 0), "duplicate active-copy release passes through");
            require(fixture.reader.reads == cycle + 1, "duplicate release cannot repeat selection acquisition");
        }
        require(route(fixture.monitor, kCGEventKeyDown, key, flags), "begin a selection gesture before unrelated input");
        if (presses == 2) {
            require(route(fixture.monitor, kCGEventKeyUp, key, flags), "release the first custom-copy press");
            require(route(fixture.monitor, kCGEventKeyDown, key, flags), "trigger custom copy before unrelated input");
        }
        require(!route(fixture.monitor, kCGEventKeyDown, 0, 0), "unrelated typing passes through and cancels pending copy");
        require(route(fixture.monitor, kCGEventKeyUp, key, 0), "cancelled copy still drains the captured release");
        require(fixture.reader.reads == 2, "unrelated down prevents a stale deferred copy");
    }
}

static void testSelectionTrial(NSPanel *panel) {
    RoutingFixture fixture;
    ShortcutPreferences *preferences = fixture.preferences;
    RoutingMonitor *monitor = fixture.monitor;
    __block unsigned copies = 0;
    __block NSString *copiedText = nil;
    monitor.onSelection = ^(SelectionResult *result) {
        require(result.kind == SelectionResultKindTrial, "selection trial emits a trial result");
        ++copies;
        copiedText = result.text;
    };
    // Only the focused, fully selected onboarding sample may use selection shortcuts
    // during configuration. The production recognizer handles both passive and custom bindings.
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
    for (unsigned press = 0; press < 2; ++press) {
        require(!route(monitor, kCGEventKeyDown, 17, kCGEventFlagMaskAlternate), "configuration still receives the panel shortcut down");
        require(!route(monitor, kCGEventKeyUp, 17, kCGEventFlagMaskAlternate), "configuration still receives the panel shortcut release");
    }
    settle();
    require(fixture.actions.opens == 0 && copies == 1, "the trial scope never opens the panel action");

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

    require(fixture.reader.begins == 0 && fixture.reader.reads == 0,
            "local trials do not call the external selection reader");
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
        RoutingSelectionReader *selectionReader = [RoutingSelectionReader new];
        RoutingMonitor *monitor = [[RoutingMonitor alloc] initWithPreferences:preferences selectionReader:selectionReader];
        __block unsigned opens = 0;
        monitor.onOpenPanel = ^{ ++opens; };
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

        testSelectionTrial(panel);

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
        require(selectionReader.begins == 1 && selectionReader.lastPassive && selectionReader.reads == 1,
                "native commands bypass selection acquisition; only the final passive pair reads");
        testHeldKeyReconfiguration();
        testSelectionCallbacks();
        testIndependentModes();
        testCancellationAndRecovery();
        testRepeatedTriggersAndDeferredCopy();
        std::cout << "Shortcut monitor native routing tests passed\n";
    }
}
