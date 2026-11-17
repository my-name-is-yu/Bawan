#import "OnboardingViewController.h"
#import "BawanAppearance.h"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <stdexcept>

@interface OnboardingSmokeMonitor : ShortcutMonitor {
    ShortcutPreferences *_testPreferences;
}
@property(nonatomic) ShortcutAvailability selectionAvailability;
@property(nonatomic) ShortcutAvailability panelAvailability;
@property(nonatomic) BOOL permissionsGranted;
@property(nonatomic) NSUInteger permissionRequests;
@property(nonatomic) bawan::ShortcutAction lastPermissionAction;
@end

@implementation OnboardingSmokeMonitor
- (instancetype)initWithPreferences:(ShortcutPreferences *)preferences {
    self = [super initWithPreferences:preferences];
    if (self) {
        _testPreferences = preferences;
        _selectionAvailability = ShortcutAvailabilityNeedsInputMonitoring;
        _panelAvailability = ShortcutAvailabilityNeedsAccessibility;
    }
    return self;
}
- (void)start {}
- (void)stop {}
- (void)refresh {
    if (_permissionsGranted) {
        _selectionAvailability = ShortcutAvailabilityAvailable;
        _panelAvailability = ShortcutAvailabilityAvailable;
    }
}
- (ShortcutAvailability)availabilityForAction:(bawan::ShortcutAction)action {
    if (![_testPreferences bindingForAction:action].enabled) return ShortcutAvailabilityOff;
    return action == bawan::ShortcutAction::TranslateSelection ?
        _selectionAvailability : _panelAvailability;
}
- (void)requestPermissionForAction:(bawan::ShortcutAction)action {
    ++_permissionRequests;
    _lastPermissionAction = action;
}
@end

static void Require(BOOL condition, NSString *message) {
    if (!condition) throw std::runtime_error(message.UTF8String);
}

static NSView *FindView(NSView *view, NSString *identifier) {
    if ([view.identifier isEqualToString:identifier]) return view;
    for (NSView *child in view.subviews) {
        if (NSView *found = FindView(child, identifier)) return found;
    }
    return nil;
}

static void Settle(NSWindow *window) {
    [window.contentView layoutSubtreeIfNeeded];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    [window.contentView layoutSubtreeIfNeeded];
}

static BOOL IsShown(NSView *view) {
    return view && !view.hiddenOrHasHiddenAncestor;
}

static void CheckBounds(NSWindow *window) {
    Settle(window);
    NSView *root = window.contentView;
    NSScrollView *scroll = (NSScrollView *)FindView(root, @"onboarding-scroll");
    NSView *document = FindView(root, @"onboarding-document");
    Require(!root.hasAmbiguousLayout && !document.hasAmbiguousLayout &&
        [scroll isKindOfClass:NSScrollView.class] && scroll.documentView == document &&
        scroll.hasVerticalScroller && !scroll.hasHorizontalScroller,
        [NSString stringWithFormat:@"The onboarding must use one unambiguous vertically scrollable document: root=%@ document=%@ frame=%@ clip=%@",
            @(root.hasAmbiguousLayout), @(document.hasAmbiguousLayout),
            NSStringFromRect(document.frame), NSStringFromRect(scroll.contentView.bounds)]);
    for (NSString *identifier in @[@"onboarding-header", @"onboarding-mascot", @"onboarding-back",
            @"onboarding-hero-mascot", @"onboarding-title", @"onboarding-model-status",
            @"onboarding-model-license", @"onboarding-shortcut-selection-title",
            @"onboarding-shortcut-selection-key", @"onboarding-shortcut-selection-status",
            @"onboarding-shortcut-selection-setup", @"onboarding-shortcut-panel-title",
            @"onboarding-shortcut-panel-key", @"onboarding-shortcut-panel-status",
            @"onboarding-shortcut-panel-setup", @"onboarding-start"]) {
        NSView *view = FindView(root, identifier);
        Require(view != nil, [@"Missing onboarding control: " stringByAppendingString:identifier]);
        if (!IsShown(view)) continue;
        NSView *container = [view isDescendantOf:document] ? document : root;
        NSRect bounds = [view convertRect:view.bounds toView:container];
        Require(bounds.size.width > 0 && bounds.size.height > 0 &&
            NSContainsRect(NSInsetRect(container.bounds, -0.5, -0.5), bounds),
            [NSString stringWithFormat:@"Onboarding view is clipped: %@ %@ in %@", identifier,
                NSStringFromRect(bounds), NSStringFromRect(container.bounds)]);
    }
    Require(document.bounds.size.width <= scroll.contentView.bounds.size.width + 1,
        @"Onboarding must remain readable without horizontal scrolling at minimum size");
    if (NSWidth(root.bounds) >= 700 && NSHeight(root.bounds) >= 490) {
        NSView *start = FindView(root, @"onboarding-start");
        NSRect startRect = [start convertRect:start.bounds toView:document];
        Require(NSContainsRect(NSInsetRect(document.visibleRect, -0.5, -0.5), startRect),
            @"The ready-state Start action must be visible without scrolling at the normal window size");
    }
}

static void Capture(NSWindow *window, NSString *name) {
    Settle(window);
    NSView *root = window.contentView;
    NSBitmapImageRep *bitmap = [root bitmapImageRepForCachingDisplayInRect:root.bounds];
    Require(bitmap != nil, @"Could not create the onboarding capture");
    [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [root cacheDisplayInRect:root.bounds toBitmapImageRep:bitmap];
    }];
    NSError *error = nil;
    Require([NSFileManager.defaultManager createDirectoryAtPath:@"onboarding-smoke"
        withIntermediateDirectories:YES attributes:nil error:&error], @"Could not create onboarding capture folder");
    NSString *path = [@"onboarding-smoke" stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    Require([png writeToFile:path atomically:YES], @"Could not save the onboarding capture");
}

static void RunSmoke(void) {
    NSString *suite = [@"local.bawan.OnboardingSmoke." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    ShortcutPreferences *preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
    OnboardingSmokeMonitor *monitor = [[OnboardingSmokeMonitor alloc] initWithPreferences:preferences];
    OnboardingViewController *onboarding = [[OnboardingViewController alloc]
        initWithPreferences:preferences monitor:monitor];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 720, 500)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                  NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;
    window.contentView = onboarding.view;
    [NSApp activateIgnoringOtherApps:YES];
    [window makeKeyAndOrderFront:nil];
    __block NSUInteger setups = 0, licenses = 0, completions = 0;
    onboarding.onModelSetup = ^{ ++setups; };
    onboarding.onModelLicense = ^{ ++licenses; };
    onboarding.onBack = ^{ ++completions; };
    @try {
        NSView *root = onboarding.view;
        Require([root.identifier isEqualToString:@"bawan-onboarding"], @"The first-run page needs its own view identity");
        NSButton *start = (NSButton *)FindView(root, @"onboarding-start");
        NSButton *modelSetup = (NSButton *)FindView(root, @"onboarding-model-setup");
        NSButton *license = (NSButton *)FindView(root, @"onboarding-model-license");
        NSProgressIndicator *progress = (NSProgressIndicator *)FindView(root, @"onboarding-model-progress");
        NSTextField *modelMessage = (NSTextField *)FindView(root, @"onboarding-model-message");
        NSButton *selectionSetup = (NSButton *)FindView(root, @"onboarding-shortcut-selection-setup");
        NSButton *panelSetup = (NSButton *)FindView(root, @"onboarding-shortcut-panel-setup");
        NSTextField *selectionStatus = (NSTextField *)FindView(root, @"onboarding-shortcut-selection-status");
        NSTextField *panelStatus = (NSTextField *)FindView(root, @"onboarding-shortcut-panel-status");
        Require(start && modelSetup && license && progress && modelMessage && selectionSetup &&
            panelSetup && selectionStatus && panelStatus, @"The first-run page must expose each required setup control");
        [onboarding refresh];
        [onboarding setActive:YES];
        [onboarding setActive:NO];
        Require(monitor.permissionRequests == 0,
            @"Creating, refreshing and activating onboarding must not request OS permissions");

        [onboarding setModelPhase:BawanModelSetupNeedsDownload message:@"Review the model license before setup." progress:0];
        Require(!start.enabled && IsShown(modelSetup) && modelSetup.enabled,
            @"An unprepared model must offer setup and keep translation disabled");
        Require([modelMessage.stringValue containsString:@"license"] &&
            [modelMessage.stringValue containsString:@"573 MB"] && modelSetup.frame.size.height >= 36,
            @"First setup must explain the license and model download beside a clear primary setup action");
        Capture(window, @"needs-download");
        [start performClick:nil];
        [modelSetup performClick:nil];
        Require(completions == 0 && setups == 1,
            @"Model setup must reach the owner without completing an unusable first-run flow");
        [license performClick:nil];
        Require(licenses == 1, @"The model license action must remain available during setup");

        [onboarding setModelPhase:BawanModelSetupPreparing message:@"Downloading the translation model…" progress:0.37];
        Settle(window);
        Require(!start.enabled && (!IsShown(modelSetup) || !modelSetup.enabled) &&
            IsShown(progress) && !progress.indeterminate && progress.maxValue > 0 &&
            std::abs(progress.doubleValue / progress.maxValue - 0.37) < 0.01 &&
            [modelMessage.stringValue containsString:@"Downloading"],
            @"Model preparation must show its real progress and remain non-completable");
        Capture(window, @"preparing");

        NSString *failure = @"The model could not be verified. Check available disk space and try again.";
        [onboarding setModelPhase:BawanModelSetupFailed message:failure progress:0];
        Require(!start.enabled && IsShown(modelSetup) && modelSetup.enabled &&
            [modelSetup.title localizedCaseInsensitiveContainsString:@"Retry"] &&
            [modelMessage.stringValue isEqualToString:failure],
            @"A failed setup must retain its error and offer an explicit retry");
        [modelSetup performClick:nil];
        Require(setups == 2 && completions == 0, @"Retry must reach setup without completing onboarding");
        Capture(window, @"failed");

        [onboarding setModelPhase:BawanModelSetupReady message:@"Ready" progress:1];
        Require(start.enabled && !IsShown(modelSetup) &&
            [selectionStatus.stringValue containsString:@"Input Monitoring"] &&
            [panelStatus.stringValue containsString:@"Accessibility"],
            @"A ready model must allow translation while both optional shortcut permissions are missing");
        [selectionSetup performClick:nil];
        Require(monitor.permissionRequests == 1 &&
            monitor.lastPermissionAction == bawan::ShortcutAction::TranslateSelection,
            @"Selection setup must request only the selected-text shortcut's permission");
        [panelSetup performClick:nil];
        Require(monitor.permissionRequests == 2 && monitor.lastPermissionAction == bawan::ShortcutAction::OpenPanel,
            @"Window shortcut setup must reach its own permission action");

        auto binding = [preferences bindingForAction:bawan::ShortcutAction::OpenPanel];
        binding.enabled = false;
        NSString *error = nil;
        Require([preferences setBinding:binding forAction:bawan::ShortcutAction::OpenPanel error:&error],
            @"The optional window shortcut must be independently disableable");
        [onboarding refresh];
        Require([panelStatus.stringValue isEqualToString:@"Off"] &&
            ![preferences bindingForAction:bawan::ShortcutAction::OpenPanel].enabled && monitor.permissionRequests == 2,
            @"Refreshing an intentionally disabled shortcut must preserve Off without asking for permission");
        [panelSetup performClick:nil];
        Require([preferences bindingForAction:bawan::ShortcutAction::OpenPanel].enabled &&
            monitor.permissionRequests == 3 && monitor.lastPermissionAction == bawan::ShortcutAction::OpenPanel,
            @"Explicit setup may enable the chosen optional shortcut and request its own permission");

        auto duplicate = [preferences bindingForAction:bawan::ShortcutAction::TranslateSelection];
        duplicate.enabled = false;
        Require([preferences setBinding:duplicate forAction:bawan::ShortcutAction::OpenPanel error:&error],
            @"A disabled duplicate fixture must be accepted until it is enabled");
        [onboarding refresh];
        [panelSetup performClick:nil];
        NSTextField *shortcutError = (NSTextField *)FindView(root, @"onboarding-error");
        Require(monitor.permissionRequests == 3 &&
            ![preferences bindingForAction:bawan::ShortcutAction::OpenPanel].enabled &&
            IsShown(shortcutError) && shortcutError.stringValue.length && start.enabled,
            @"A shortcut conflict must stay local, preserve the old preference and never gate manual translation");
        Require([preferences restoreAction:bawan::ShortcutAction::OpenPanel error:&error],
            @"The default window shortcut must be restorable after an optional conflict");
        [onboarding refresh];
        [panelSetup performClick:nil];
        Require(monitor.permissionRequests == 4 && !IsShown(shortcutError),
            @"A valid setup action after a shortcut conflict must recover and clear the obsolete error");

        monitor.permissionsGranted = YES;
        [onboarding setActive:YES];
        Require([selectionStatus.stringValue isEqualToString:@"Shortcut ready"] &&
            [panelStatus.stringValue isEqualToString:@"Shortcut ready"] && start.enabled,
            @"Returning after permission changes must replace stale setup warnings with actual readiness");
        [onboarding setActive:NO];
        monitor.permissionsGranted = NO;
        monitor.selectionAvailability = ShortcutAvailabilityNeedsInputMonitoring;
        monitor.panelAvailability = ShortcutAvailabilityNeedsAccessibility;
        [onboarding refresh];
        [onboarding focusInitialControl];
        NSResponder *focused = window.firstResponder;
        Require([focused isKindOfClass:NSView.class] &&
            (focused == root || [(NSView *)focused isDescendantOf:root]),
            @"Initial keyboard focus must belong to the visible onboarding page");
        [start performClick:nil];
        Require(completions == 1, @"Starting translation must invoke the owner's completion action once");
        [(NSButton *)FindView(root, @"onboarding-back") performClick:nil];
        Require(completions == 2, @"Ready-state Back must use the same completion action");

        for (NSValue *size in @[[NSValue valueWithSize:NSMakeSize(720, 500)],
                                [NSValue valueWithSize:NSMakeSize(640, 420)]]) {
            [window setContentSize:size.sizeValue];
            NSString *prefix = size.sizeValue.width < 700 ? @"minimum" : @"ready";
            window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
            CheckBounds(window);
            Capture(window, [prefix stringByAppendingString:@"-light"]);
            window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
            CheckBounds(window);
            Capture(window, [prefix stringByAppendingString:@"-dark"]);
            if (size.sizeValue.width < 700) {
                [start scrollRectToVisible:start.bounds];
                Settle(window);
                Require(NSContainsRect(NSInsetRect(start.visibleRect, -0.5, -0.5), start.bounds),
                    @"The primary action must remain fully reachable by scrolling at minimum size");
                Capture(window, @"minimum-dark-scrolled");
            }
        }
        std::cout << "PASS: onboarding phases, optional permissions, callbacks, state refresh and responsive captures\n";
    } @finally {
        [onboarding setActive:NO];
        [window orderOut:nil];
        [window close];
        [defaults removePersistentDomainForName:suite];
    }
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        __block int result = EXIT_FAILURE;
        [NSRunLoop.mainRunLoop performBlock:^{
            @try {
                try { RunSmoke(); result = EXIT_SUCCESS; }
                catch (const std::exception &error) { std::cerr << "Onboarding smoke failed: " << error.what() << '\n'; }
            } @catch (NSException *exception) {
                std::cerr << "Onboarding smoke failed: " << exception.reason.UTF8String << '\n';
            }
            [NSApp stop:nil];
            [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
                modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:0 context:nil
                subtype:0 data1:0 data2:0] atStart:NO];
        }];
        [NSApp run];
        return result;
    }
}
