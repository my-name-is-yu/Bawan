#import "OnboardingViewController.h"
#import "TranslationPanel.h"
#import "BawanChrome.h"
#import "BawanMascotView.h"
#import <QuartzCore/QuartzCore.h>
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

@interface OnboardingSmokeController : OnboardingViewController
@property(nonatomic) NSUInteger refreshes;
@end

@implementation OnboardingSmokeController
- (void)refresh {
    ++_refreshes;
    [super refresh];
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
    for (NSString *identifier in @[@"onboarding-header", @"onboarding-mascot", @"onboarding-footer",
            @"onboarding-footer-note", @"onboarding-step-model", @"onboarding-step-shortcut",
            @"onboarding-title", @"onboarding-model-status", @"onboarding-model-message",
            @"onboarding-primary", @"onboarding-model-license", @"onboarding-shortcut-title",
            @"onboarding-shortcut-selection-title", @"onboarding-shortcut-selection-key",
            @"onboarding-shortcut-selection-status", @"onboarding-shortcut-selection-setup",
            @"onboarding-shortcut-panel-title", @"onboarding-shortcut-panel-key",
            @"onboarding-shortcut-panel-status", @"onboarding-shortcut-panel-setup",
            @"onboarding-selection-trial", @"onboarding-trial-sample", @"onboarding-trial-instructions",
            @"onboarding-trial-status"]) {
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
    NSView *footer = FindView(root, @"onboarding-footer");
    for (NSString *identifier in @[@"onboarding-primary", @"onboarding-model-license"]) {
        NSView *button = FindView(root, identifier);
        Require([button isDescendantOf:footer] && ![button isDescendantOf:document],
            [identifier stringByAppendingString:@" must stay in the fixed footer, visible without scrolling"]);
    }
    NSRect selectionRow = [FindView(root, @"onboarding-shortcut-selection-row") convertRect:NSZeroRect toView:root];
    NSRect panelRow = [FindView(root, @"onboarding-shortcut-panel-row") convertRect:NSZeroRect toView:root];
    Require(IsShown(FindView(root, @"onboarding-step-model")) || NSMinY(selectionRow) != NSMinY(panelRow),
        @"The shortcut step must list both shortcuts as separate rows");
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

static void ServiceQueuedAppEvents(NSWindow *window) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
    unsigned dispatched = 0;
    while ((!NSApp.active || !window.isKeyWindow) && deadline.timeIntervalSinceNow > 0) {
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
            untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]
            inMode:NSDefaultRunLoopMode dequeue:YES];
        if (event) { [NSApp sendEvent:event]; ++dispatched; }
        [window makeKeyWindow];
    }
    std::cerr << "APP EVENTS dispatched=" << dispatched
        << " appActive=" << NSApp.active
        << " runningAppActive=" << NSRunningApplication.currentApplication.active
        << " key=" << window.isKeyWindow << "\n";
}

static void RunSmoke(void) {
    NSString *suite = [@"local.bawan.OnboardingSmoke." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    ShortcutPreferences *preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
    OnboardingSmokeMonitor *monitor = [[OnboardingSmokeMonitor alloc] initWithPreferences:preferences];
    OnboardingSmokeController *onboarding = [[OnboardingSmokeController alloc]
        initWithPreferences:preferences monitor:monitor];
    TranslationPanel *panel = [[TranslationPanel alloc] init];
    NSWindow *window = panel.window;
    // Programmatic fixture actions have no mouse hit to request panel keyboard focus.
    ((NSPanel *)window).becomesKeyOnlyIfNeeded = NO;
    [window setContentSize:NSMakeSize(720, 500)];
    __block NSUInteger setups = 0, licenses = 0, finishes = 0, backs = 0;
    onboarding.onModelSetup = ^{ ++setups; };
    onboarding.onModelLicense = ^{ ++licenses; };
    onboarding.onFinish = ^{ ++finishes; };
    @try {
        [panel showOnboarding:onboarding onBack:^{ ++backs; }];
        ServiceQueuedAppEvents(window);
        [window makeKeyWindow];
        Settle(window);
        Require(window.canBecomeKeyWindow && window.visible && window.isKeyWindow && NSApp.keyWindow == window,
            [NSString stringWithFormat:@"Onboarding fixture cannot own keyboard focus: canKey=%d visible=%d key=%d appKey=%@ active=%d running=%d policy=%ld menu=%@ responder=%@ rootNeedsKey=%d sampleAcceptsFocus=%d sampleNeedsKey=%d panelKeyOnlyIfNeeded=%d",
                window.canBecomeKeyWindow, window.visible, window.isKeyWindow, NSApp.keyWindow,
                NSApp.active, NSApp.running, (long)NSApp.activationPolicy, NSApp.mainMenu, window.firstResponder,
                onboarding.view.needsPanelToBecomeKey,
                FindView(onboarding.view, @"onboarding-trial-sample").acceptsFirstResponder,
                FindView(onboarding.view, @"onboarding-trial-sample").needsPanelToBecomeKey,
                ((NSPanel *)window).becomesKeyOnlyIfNeeded]);
        NSView *root = onboarding.view;
        Require([root.identifier isEqualToString:@"bawan-onboarding"], @"The first-run page needs its own view identity");
        NSView *modelStep = FindView(root, @"onboarding-step-model");
        NSView *shortcutStep = FindView(root, @"onboarding-step-shortcut");
        // One footer button serves both steps: Download or Retry, then Set Up Later or Start.
        NSButton *primary = (NSButton *)FindView(root, @"onboarding-primary");
        NSButton *license = (NSButton *)FindView(root, @"onboarding-model-license");
        NSTextField *note = (NSTextField *)FindView(root, @"onboarding-footer-note");
        NSTextField *modelMessage = (NSTextField *)FindView(root, @"onboarding-model-message");
        NSButton *selectionSetup = (NSButton *)FindView(root, @"onboarding-shortcut-selection-setup");
        NSTextField *selectionStatus = (NSTextField *)FindView(root, @"onboarding-shortcut-selection-status");
        NSButton *panelSetup = (NSButton *)FindView(root, @"onboarding-shortcut-panel-setup");
        NSTextField *panelStatus = (NSTextField *)FindView(root, @"onboarding-shortcut-panel-status");
        NSTextField *shortcutError = (NSTextField *)FindView(root, @"onboarding-error");
        NSView *trial = FindView(root, @"onboarding-selection-trial");
        NSTextView *sample = (NSTextView *)FindView(root, @"onboarding-trial-sample");
        NSTextField *instructions = (NSTextField *)FindView(root, @"onboarding-trial-instructions");
        NSTextField *trialStatus = (NSTextField *)FindView(root, @"onboarding-trial-status");
        Require(modelStep && shortcutStep && primary && license && note && modelMessage &&
            selectionSetup && selectionStatus && panelSetup && panelStatus && shortcutError &&
            trial && sample && instructions && trialStatus,
            @"The first-run page must expose each setup control");
        [onboarding refresh];
        [onboarding setActive:YES];
        [onboarding setActive:NO];
        Require(monitor.permissionRequests == 0,
            @"Creating, refreshing and activating onboarding must not request OS permissions");

        // Step 1: the model. Download and Model License are the only actions.
        [onboarding setModelPhase:BawanModelSetupNeedsDownload message:@"" progress:0];
        Settle(window);
        Require(IsShown(modelStep) && !IsShown(shortcutStep) && IsShown(primary) && IsShown(license) &&
            [primary.title hasPrefix:@"Download Model"] &&
            [primary isKindOfClass:BawanActionButton.class] && ((BawanActionButton *)primary).primary &&
            [modelMessage.stringValue containsString:@"license"] && [modelMessage.stringValue containsString:@"573 MB"],
            @"The model step must explain the download and offer only Download and Model License");
        CheckBounds(window);
        Capture(window, @"needs-download");
        // The centered dog animates like the masthead medallion.
        BawanMascotView *hero = (BawanMascotView *)FindView(root, @"onboarding-hero-mascot");
        Require([hero isKindOfClass:BawanMascotView.class] && IsShown(hero),
            @"The model step must center the animated mascot");
        if (!NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
            [hero mouseEntered:[NSEvent enterExitEventWithType:NSEventTypeMouseEntered location:NSZeroPoint
                modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil
                eventNumber:0 trackingNumber:0 userData:nullptr]];
            CALayer *dog = nil;
            for (CALayer *clip in hero.layer.sublayers)
                for (CALayer *layer in clip.sublayers)
                    if ([layer.name isEqualToString:@"bawan.mascot.dog"]) dog = layer;
            Require([dog animationForKey:@"bawan.hover"] != nil, @"Hovering the centered mascot must play its motion");
            [hero resetHoverAnimation];
        }
        [primary performClick:nil];
        [license performClick:nil];
        Require(setups == 1 && licenses == 1 && finishes == 0,
            @"Download and Model License must reach their owner actions without finishing onboarding");
        [onboarding performPrimaryAction];
        Require(setups == 2, @"⌘Return on the model step must start the download");

        // Step 2: preparation moves on to the shortcut while the model downloads.
        // The footer repeats ModelStore's own words, so checking and verifying never read as downloading.
        [onboarding setModelPhase:BawanModelSetupPreparing message:@"Checking the saved model…" progress:0];
        Settle(window);
        Require([note.stringValue isEqualToString:@"Checking the saved model…"],
            @"Checking a saved model must not be reported as a download");
        [onboarding setModelPhase:BawanModelSetupPreparing message:@"Downloading the model… 37%" progress:0.37];
        Settle(window);
        Require(!IsShown(modelStep) && IsShown(shortcutStep) && IsShown(primary) && primary.enabled &&
            !IsShown(license) && [note.stringValue isEqualToString:@"Downloading the model… 37%"],
            @"Downloading must show the shortcut step, its progress in the footer, and an enabled continue action");
        Require([primary.title hasPrefix:@"Set Up Later"] && [selectionStatus.stringValue containsString:@"Input Monitoring"] &&
            [panelStatus.stringValue containsString:@"Accessibility"],
            @"While either shortcut needs permission, the single footer action must read Set Up Later");
        Require(!IsShown(trial) && monitor.selectionTrialView == nil,
            @"The practice sentence must be hidden while selection permission is missing");
        CheckBounds(window);
        Capture(window, @"preparing");
        [primary performClick:nil];
        Require(finishes == 1, @"Set Up Later must leave onboarding even while the model is still downloading");

        [selectionSetup performClick:nil];
        Require(monitor.permissionRequests == 1 &&
            monitor.lastPermissionAction == bawan::ShortcutAction::TranslateSelection,
            @"Selection Set Up must request only the selection shortcut's permission");
        [panelSetup performClick:nil];
        Require(monitor.permissionRequests == 2 && monitor.lastPermissionAction == bawan::ShortcutAction::OpenPanel,
            @"Open Translator Set Up must request its own permission");

        // A conflict while enabling stays local and never blocks continuing.
        NSString *error = nil;
        auto selection = [preferences bindingForAction:bawan::ShortcutAction::TranslateSelection];
        auto panel = selection;
        selection.enabled = false;
        Require([preferences setBinding:selection forAction:bawan::ShortcutAction::TranslateSelection error:&error] &&
            [preferences setBinding:panel forAction:bawan::ShortcutAction::OpenPanel error:&error],
            @"The conflict fixture must give the window shortcut the selection key");
        [onboarding refresh];
        Require([selectionStatus.stringValue isEqualToString:@"Off"],
            @"A disabled selection shortcut must read Off without asking for permission");
        [selectionSetup performClick:nil];
        Require(monitor.permissionRequests == 2 && IsShown(shortcutError) && shortcutError.stringValue.length &&
            ![preferences bindingForAction:bawan::ShortcutAction::TranslateSelection].enabled && primary.enabled,
            @"A shortcut conflict must stay local, keep the old preference and never block continuing");
        Require([preferences restoreAction:bawan::ShortcutAction::OpenPanel error:&error],
            @"The window shortcut must be restorable after the conflict");
        [onboarding refresh];
        [selectionSetup performClick:nil];
        Require(monitor.permissionRequests == 3 && !IsShown(shortcutError) &&
            [preferences bindingForAction:bawan::ShortcutAction::TranslateSelection].enabled,
            @"Set Up after resolving the conflict must enable the shortcut and clear the error");

        // A failed download returns to the model step with Retry.
        NSString *failure = @"The model could not be verified. Check available disk space and try again.";
        [onboarding setModelPhase:BawanModelSetupFailed message:failure progress:0];
        Settle(window);
        Require(IsShown(modelStep) && !IsShown(shortcutStep) && IsShown(primary) &&
            [primary.title localizedCaseInsensitiveContainsString:@"Retry"] &&
            [modelMessage.stringValue isEqualToString:failure],
            @"A failed download must return to the model step with its error and Retry");
        Capture(window, @"failed");
        [primary performClick:nil];
        Require(setups == 3 && finishes == 1, @"Retry must reach setup without finishing onboarding");

        // Availability reveals the trial; only its actual translation outcome completes it.
        [onboarding setModelPhase:BawanModelSetupReady message:BawanModelReadyStatus progress:1];
        monitor.permissionsGranted = YES;
        [onboarding setActive:YES];
        Require(IsShown(shortcutStep) && [selectionStatus.stringValue isEqualToString:@"Shortcut ready"] &&
            [panelStatus.stringValue isEqualToString:@"Shortcut ready"] && !IsShown(selectionSetup) &&
            !IsShown(panelSetup) && [primary.title hasPrefix:@"Set Up Later"] && IsShown(trial) &&
            sample.selectable && !sample.editable && !sample.richText && sample.string.length &&
            [instructions.stringValue containsString:@"⌘C"] && [instructions.stringValue containsString:@"twice"] &&
            [note.stringValue isEqualToString:BawanModelReadyStatus] && !IsShown(trialStatus),
            @"Ready settings must offer a selectable sample with current instructions without claiming it was tried");
        [window makeFirstResponder:sample];
        sample.selectedRange = NSMakeRange(0, sample.string.length);
        Require([onboarding isSelectionTrialText:sample.string] && !onboarding.selectionTrialComplete &&
            [primary.title hasPrefix:@"Set Up Later"],
            @"Selecting the sample alone must not complete the trial");
        Require(![onboarding isSelectionTrialText:@"A different sentence"],
            @"A different selected sentence cannot count as this practice sentence");
        NSUInteger attempt = [onboarding beginSelectionTrial];
        Require(attempt && [onboarding beginSelectionTrial] == 0 && IsShown(trialStatus) &&
            [primary.title hasPrefix:@"Set Up Later"],
            @"The real shortcut may start one trial at a time and must wait for translation");
        onboarding.refreshes = 0;
        Require([onboarding isSelectionTrialCurrent:attempt] && [onboarding isSelectionTrialCurrent:attempt] &&
            onboarding.refreshes == 0,
            @"Checking the active trial must not render the page");
        [onboarding refresh];
        Require([onboarding isSelectionTrialCurrent:attempt] && onboarding.refreshes == 1 &&
            IsShown(trialStatus) && [primary.title hasPrefix:@"Set Up Later"],
            @"One explicit state refresh followed by a trial check must render once and preserve the pending trial");
        CheckBounds(window);
        Capture(window, @"trial-translating");
        Require(![onboarding finishSelectionTrial:attempt + 1 output:@"Unrelated output"
            direction:bawan::Direction::EnglishToJapanese] && !onboarding.selectionTrialComplete,
            @"An unrelated completion must not finish the current trial");
        Require(![onboarding finishSelectionTrial:attempt output:@"  " direction:bawan::Direction::EnglishToJapanese] &&
            !onboarding.selectionTrialComplete && [primary.title hasPrefix:@"Set Up Later"],
            @"An empty or failed translation must leave the trial retryable");
        attempt = [onboarding beginSelectionTrial];
        Require(attempt && [onboarding finishSelectionTrial:attempt output:@"小さな一歩が新しい世界を開く。"
            direction:bawan::Direction::EnglishToJapanese] && IsShown(trialStatus) &&
            [trialStatus.stringValue containsString:@"successfully"] &&
            [primary.title hasPrefix:@"Start Translating"] && onboarding.selectionTrialComplete &&
            [onboarding.selectionTrialOutput isEqualToString:@"小さな一歩が新しい世界を開く。"] &&
            [onboarding beginSelectionTrial] == 0,
            @"Only the practice request's successful result may complete the trial, once");
        CheckBounds(window);
        Capture(window, @"trial-complete");
        [window setContentSize:NSMakeSize(640, 420)];
        window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        CheckBounds(window);
        Capture(window, @"trial-complete-minimum-dark");
        [window setContentSize:NSMakeSize(720, 500)];
        window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        [onboarding setActive:NO];
        [onboarding setActive:YES];
        Require(onboarding.selectionTrialComplete && [primary.title hasPrefix:@"Start Translating"],
            @"Revisiting with the same usable binding must preserve a completed practice result");
        [onboarding performPrimaryAction];
        Require(finishes == 2 && backs == 0, @"⌘Return on the shortcut step must finish onboarding");

        // Selection readiness is independent of the window shortcut; current bindings drive the guide.
        monitor.permissionsGranted = NO;
        monitor.panelAvailability = ShortcutAvailabilityNeedsAccessibility;
        selection = [preferences bindingForAction:bawan::ShortcutAction::TranslateSelection];
        selection.keyCode = 40;
        selection.modifiers = bawan::Control | bawan::Shift;
        selection.pressCount = 1;
        Require([preferences setBinding:selection forAction:bawan::ShortcutAction::TranslateSelection error:&error],
            @"The custom selection fixture must be valid");
        [onboarding refresh];
        Require(IsShown(trial) && !onboarding.selectionTrialComplete &&
            [instructions.stringValue containsString:@"⌃⇧K"] && [instructions.stringValue containsString:@"once"] &&
            ![instructions.stringValue containsString:@"⌘C"] && [primary.title hasPrefix:@"Set Up Later"],
            @"Changing the binding must reset success and describe the custom key/count even if the panel lacks permission");
        [window makeFirstResponder:sample];
        sample.selectedRange = NSMakeRange(0, sample.string.length);
        attempt = [onboarding beginSelectionTrial];
        Require(attempt && [onboarding isSelectionTrialCurrent:attempt], @"The revisit fixture must start a practice request");
        [onboarding setActive:NO];
        [onboarding setActive:YES];
        Require(![onboarding finishSelectionTrial:attempt output:@"Late page output"
            direction:bawan::Direction::EnglishToJapanese] && !onboarding.selectionTrialComplete,
            @"Leaving a pending trial must reject its late completion when the page is revisited");
        [window makeFirstResponder:sample];
        sample.selectedRange = NSMakeRange(0, sample.string.length);
        attempt = [onboarding beginSelectionTrial];
        Require(attempt && [onboarding isSelectionTrialCurrent:attempt], @"The changed-binding fixture must start a practice request");
        onboarding.refreshes = 0;
        selection.pressCount = 2;
        Require([preferences setBinding:selection forAction:bawan::ShortcutAction::TranslateSelection error:&error],
            @"Changing press count during inference must be valid");
        Require(![onboarding isSelectionTrialCurrent:attempt] &&
            ![onboarding finishSelectionTrial:attempt output:@"Old binding output"
                direction:bawan::Direction::EnglishToJapanese] && onboarding.refreshes == 0,
            @"The live binding must reject stale completion before the page renders again");
        [onboarding refresh];
        Require(![onboarding isSelectionTrialCurrent:attempt] && onboarding.refreshes == 1 &&
            [instructions.stringValue containsString:@"twice"],
            @"An explicit refresh must update the guide and invalidate the old practice attempt once");
        [window makeFirstResponder:sample];
        sample.selectedRange = NSMakeRange(0, sample.string.length);
        attempt = [onboarding beginSelectionTrial];
        Require(attempt && [onboarding isSelectionTrialCurrent:attempt], @"The revoked-permission fixture must start a practice request");
        onboarding.refreshes = 0;
        monitor.selectionAvailability = ShortcutAvailabilityNeedsAccessibility;
        Require(![onboarding isSelectionTrialCurrent:attempt] &&
            ![onboarding finishSelectionTrial:attempt output:@"Revoked permission output"
                direction:bawan::Direction::EnglishToJapanese] && onboarding.refreshes == 0,
            @"Live permission loss must reject completion before a page refresh without rendering from the query");
        [onboarding refresh];
        Require(!IsShown(trial) && monitor.selectionTrialView == nil && onboarding.refreshes == 1 &&
            ![onboarding finishSelectionTrial:attempt output:@"Revoked permission output"
                direction:bawan::Direction::EnglishToJapanese] && [primary.title hasPrefix:@"Set Up Later"],
            @"Revoking permission must hide practice and reject its pending result");
        for (ShortcutAvailability availability : {ShortcutAvailabilityOff, ShortcutAvailabilityNeedsInputMonitoring,
                ShortcutAvailabilityNeedsAccessibility, ShortcutAvailabilityFailed}) {
            monitor.selectionAvailability = availability;
            [onboarding refresh];
            Require(!IsShown(trial) && monitor.selectionTrialView == nil && !onboarding.selectionTrialComplete,
                @"Practice must stay hidden for every unusable selection state");
        }
        monitor.selectionAvailability = ShortcutAvailabilityAvailable;
        [onboarding refresh];
        [window makeFirstResponder:sample];
        sample.selectedRange = NSMakeRange(0, sample.string.length);
        attempt = [onboarding beginSelectionTrial];
        Require(attempt && [onboarding isSelectionTrialCurrent:attempt], @"The disabled-binding fixture must start a practice request");
        onboarding.refreshes = 0;
        selection.enabled = false;
        Require([preferences setBinding:selection forAction:bawan::ShortcutAction::TranslateSelection error:&error],
            @"The shortcut may be disabled while monitoring permission remains granted");
        Require(![onboarding isSelectionTrialCurrent:attempt] &&
            ![onboarding finishSelectionTrial:attempt output:@"Disabled shortcut output"
                direction:bawan::Direction::EnglishToJapanese] && onboarding.refreshes == 0,
            @"A disabled live binding must reject completion before the next page refresh");
        [onboarding refresh];
        Require(!IsShown(trial) && onboarding.refreshes == 1,
            @"A disabled binding must hide practice in the explicit refresh even with monitor permission");
        selection.enabled = true;
        Require([preferences setBinding:selection forAction:bawan::ShortcutAction::TranslateSelection error:&error],
            @"The shortcut must be re-enabled for ready-state captures");
        [onboarding refresh];
        [onboarding focusInitialControl];
        NSResponder *focused = window.firstResponder;
        NSScrollView *scroll = (NSScrollView *)FindView(root, @"onboarding-scroll");
        Require(focused == root && scroll.contentView.bounds.origin.y == 0,
            @"Onboarding must open at the top with its ring-less surface focused");

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
        }
        std::cout << "PASS: onboarding setup, selection practice visibility, binding changes, completion, invalidation and responsive captures\n";
    } @finally {
        [onboarding setActive:NO];
        [panel close];
        [defaults removePersistentDomainForName:suite];
    }
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        if (![NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]) {
            std::cerr << "FAIL: AppKit smoke fixture could not use accessory activation policy\n";
            return EXIT_FAILURE;
        }
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
