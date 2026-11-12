#import "SettingsWindow.h"
#import <CoreGraphics/CoreGraphics.h>
#import "LoreAppearance.h"

#include <cstdlib>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <set>

@interface SmokeShortcutMonitor : ShortcutMonitor {
    ShortcutPreferences *_testPreferences;
    BOOL _testSuspended;
    BOOL _testSettingsActive;
}
@property(nonatomic) ShortcutAvailability selectionAvailability;
@property(nonatomic) ShortcutAvailability panelAvailability;
@property(nonatomic) NSUInteger permissionRequests;
@property(nonatomic) lore::ShortcutAction lastPermissionAction;
@end

@implementation SmokeShortcutMonitor
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
- (void)refresh {}
- (BOOL)suspended { return _testSuspended; }
- (void)setSuspended:(BOOL)value { _testSuspended = value; }
- (BOOL)settingsActive { return _testSettingsActive; }
- (void)setSettingsActive:(BOOL)value { _testSettingsActive = value; }
- (ShortcutAvailability)availabilityForAction:(lore::ShortcutAction)action {
    if (![_testPreferences bindingForAction:action].enabled) return ShortcutAvailabilityOff;
    return action == lore::ShortcutAction::TranslateSelection ? _selectionAvailability : _panelAvailability;
}
- (void)requestPermissionForAction:(lore::ShortcutAction)action {
    ++_permissionRequests;
    _lastPermissionAction = action;
}
@end

// Send events through NSApplication and its real local event monitor, while
// keeping physical release checks deterministic without injecting OS input.
@interface SmokeSettingsWindow : SettingsWindow {
    std::set<CGKeyCode> _testHeldKeys;
}
- (void)setRecordedKey:(CGKeyCode)key down:(BOOL)down;
@end
@implementation SmokeSettingsWindow
- (void)setRecordedKey:(CGKeyCode)key down:(BOOL)down {
    if (down) _testHeldKeys.insert(key);
    else _testHeldKeys.erase(key);
}
- (BOOL)isRecordingKeyDown:(CGKeyCode)key { return _testHeldKeys.count(key) != 0; }
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
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    [window.contentView layoutSubtreeIfNeeded];
}

static NSRect FrameInRoot(NSView *view) {
    return [view convertRect:view.bounds toView:view.window.contentView];
}

static void CheckBounds(NSWindow *window) {
    Settle(window);
    NSView *root = window.contentView;
    Require(!root.hasAmbiguousLayout, @"Settings layout is ambiguous");
    for (NSString *identifier in @[@"shortcut-selection-enabled", @"shortcut-selection-key", @"shortcut-selection-count",
            @"shortcut-selection-reset", @"shortcut-selection-status", @"shortcut-selection-permission",
            @"shortcut-panel-enabled", @"shortcut-panel-key", @"shortcut-panel-count", @"shortcut-panel-reset",
            @"shortcut-panel-status", @"shortcut-panel-permission", @"shortcut-reservation", @"shortcut-local-keys",
            @"shortcut-feedback", @"launch-at-login", @"login-items", @"login-hint",
            @"local-processing", @"shortcut-group", @"login-group", @"settings-header", @"settings-mascot",
            @"settings-brand-name", @"settings-subtitle"]) {
        NSView *view = FindView(root, identifier);
        Require(view != nil, [@"Missing settings view: " stringByAppendingString:identifier]);
        if (view.hidden) continue;
        NSRect frame = FrameInRoot(view);
        Require(frame.size.width > 0 && frame.size.height > 0 &&
                NSContainsRect(NSInsetRect(root.bounds, -0.5, -0.5), frame),
                [NSString stringWithFormat:@"Settings view clipped: %@ %@ in %@", identifier,
                    NSStringFromRect(frame), NSStringFromRect(root.bounds)]);
    }
    NSView *header = FindView(root, @"settings-header");
    NSView *mascot = FindView(root, @"settings-mascot");
    NSTextField *brand = (NSTextField *)FindView(root, @"settings-brand-name");
    NSView *subtitle = FindView(root, @"settings-subtitle");
    NSRect brandFrame = [brand convertRect:brand.bounds toView:header];
    NSRect mascotFrame = [mascot convertRect:mascot.bounds toView:header];
    NSRect subtitleFrame = [subtitle convertRect:subtitle.bounds toView:header];
    Require(std::abs(header.bounds.size.height - LoreHeaderHeight) < 1 &&
            std::abs(mascot.bounds.size.width - LoreBrandMarkSize) < 1 &&
            std::abs(mascot.bounds.size.height - LoreBrandMarkSize) < 1 &&
            std::abs(brand.font.pointSize - LoreBrandLogoSize) < 0.1 &&
            std::abs(NSMinX(mascotFrame) - LoreBrandLeading) < 1 &&
            std::abs(NSMinX(brandFrame) - NSMaxX(mascotFrame) - LoreBrandGap) < 1,
            @"Settings branding must use the same geometry and typography as the translator");
    Require(NSContainsRect(header.bounds, brandFrame) && NSContainsRect(header.bounds, subtitleFrame) &&
            !NSIntersectsRect(brandFrame, subtitleFrame) && !NSIntersectsRect(brandFrame, mascotFrame),
            @"Settings wordmark and subtitle must fit without overlapping the mascot or each other");
    for (NSString *identifier in @[@"shortcut-selection-key", @"shortcut-panel-key", @"shortcut-selection-count",
                                   @"shortcut-panel-count"]) {
        NSControl *control = (NSControl *)FindView(root, identifier);
        Require(std::abs(control.bounds.size.height - LoreInputHeight) < 1 &&
                std::abs(control.font.pointSize - LoreInputFontSize) < 0.1,
                @"Key recorders and press counts must share the same input height and typography");
    }
    NSView *shortcut = FindView(root, @"shortcut-group");
    NSView *login = FindView(root, @"login-group");
    NSView *privacy = FindView(root, @"local-processing");
    Require(!NSIntersectsRect(FrameInRoot(shortcut), FrameInRoot(login)) &&
            !NSIntersectsRect(FrameInRoot(login), FrameInRoot(privacy)),
            @"Settings groups and privacy footer must not overlap");
}

static CGFloat BackgroundBrightness(NSWindow *window) {
    Settle(window);
    NSView *root = window.contentView;
    NSBitmapImageRep *bitmap = [root bitmapImageRepForCachingDisplayInRect:root.bounds];
    Require(bitmap != nil, @"Could not capture the settings theme");
    [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [root cacheDisplayInRect:root.bounds toBitmapImageRep:bitmap];
    }];
    NSInteger x = static_cast<NSInteger>(8 * bitmap.pixelsWide / root.bounds.size.width);
    NSColor *color = [[bitmap colorAtX:x y:bitmap.pixelsHigh / 2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    Require(color != nil, @"Could not read the settings background");
    return color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722;
}

static void Capture(NSWindow *window, NSString *name) {
    CheckBounds(window);
    NSView *root = window.contentView;
    NSBitmapImageRep *bitmap = [root bitmapImageRepForCachingDisplayInRect:root.bounds];
    Require(bitmap != nil, @"Could not allocate settings capture");
    [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [root cacheDisplayInRect:root.bounds toBitmapImageRep:bitmap];
    }];
    // The window draws its background separately from contentView; preserve
    // that background beneath the captured view's transparent pixels.
    NSBitmapImageRep *composite = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil
        pixelsWide:bitmap.pixelsWide pixelsHigh:bitmap.pixelsHigh bitsPerSample:8 samplesPerPixel:4
        hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    composite.size = root.bounds.size;
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:composite]];
    [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [window.backgroundColor setFill];
        NSRectFill(root.bounds);
        NSImage *viewImage = [[NSImage alloc] initWithSize:root.bounds.size];
        [viewImage addRepresentation:bitmap];
        [viewImage drawInRect:root.bounds fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver fraction:1];
    }];
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [composite representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *path = [@"settings-smoke" stringByAppendingPathComponent:[name stringByAppendingString:@".png"]];
    Require([png writeToFile:path atomically:YES], @"Could not save settings capture");
}

static void RequireTint(NSWindow *window, NSColor *actual, NSColor *expected, NSString *message) {
    [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
        NSColor *a = [actual colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        NSColor *b = [expected colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        Require(a != nil && b != nil && std::abs(a.redComponent - b.redComponent) < 0.01 &&
                std::abs(a.greenComponent - b.greenComponent) < 0.01 &&
                std::abs(a.blueComponent - b.blueComponent) < 0.01, message);
    }];
}

static void RequireTintInBothAppearances(NSWindow *window, NSColor *actual, NSColor *expected, NSString *message) {
    NSAppearance *previous = window.appearance;
    for (NSAppearanceName appearance in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
        window.appearance = [NSAppearance appearanceNamed:appearance];
        RequireTint(window, actual, expected, message);
    }
    window.appearance = previous;
}

static void CheckInputFaces(NSWindow *window) {
    NSAppearance *previous = window.appearance;
    for (NSAppearanceName appearance in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
        window.appearance = [NSAppearance appearanceNamed:appearance];
        Settle(window);
        for (NSString *identifier in @[@"shortcut-selection-key", @"shortcut-panel-key", @"shortcut-selection-count",
                                       @"shortcut-panel-count"]) {
            NSView *control = FindView(window.contentView, identifier);
            NSBitmapImageRep *bitmap = [control bitmapImageRepForCachingDisplayInRect:control.bounds];
            Require(bitmap != nil, @"Could not capture a shortcut input face");
            [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
                [control cacheDisplayInRect:control.bounds toBitmapImageRep:bitmap];
            }];
            // Read empty vertical padding, clear of title glyphs, popup arrows and the border.
            NSInteger y = static_cast<NSInteger>(4 * bitmap.pixelsHigh / control.bounds.size.height);
            RequireTint(window, [bitmap colorAtX:bitmap.pixelsWide / 2 y:y], LoreColor(LoreBackground),
                [@"Native cells must preserve Lore's shared input face: " stringByAppendingString:identifier]);
        }
    }
    window.appearance = previous;
}

static void SendKey(SmokeSettingsWindow *settings, unsigned short code,
                    NSEventModifierFlags modifiers, BOOL down, NSString *characters) {
    [settings setRecordedKey:code down:down];
    NSEvent *event = [NSEvent keyEventWithType:down ? NSEventTypeKeyDown : NSEventTypeKeyUp
        location:NSZeroPoint modifierFlags:modifiers timestamp:NSProcessInfo.processInfo.systemUptime
        windowNumber:settings.window.windowNumber context:nil characters:characters
        charactersIgnoringModifiers:characters isARepeat:NO keyCode:code];
    [NSApp sendEvent:event];
}

static void SendControlAction(NSControl *control) {
    [NSApp sendAction:control.action to:control.target from:control];
}

static void RunSmoke(void) {
    [NSFileManager.defaultManager createDirectoryAtPath:@"settings-smoke"
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *suite = [@"local.lore.settings-smoke." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removePersistentDomainForName:suite];
    ShortcutPreferences *preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
    SmokeShortcutMonitor *monitor = [[SmokeShortcutMonitor alloc] initWithPreferences:preferences];
    SmokeSettingsWindow *settings = [[SmokeSettingsWindow alloc] initWithPreferences:preferences monitor:monitor];
    NSWindow *window = settings.window;
    [settings showSettings];
    CheckBounds(window);
    Require(LoreMascotImage() != nil && LorePaperImage() != nil,
            @"Settings captures must load the real mascot and paper assets");
    NSView *root = window.contentView;
    NSSwitch *login = (NSSwitch *)FindView(root, @"launch-at-login");
    NSTextField *hint = (NSTextField *)FindView(root, @"login-hint");
    NSTextField *selectionStatus = (NSTextField *)FindView(root, @"shortcut-selection-status");
    NSTextField *panelStatus = (NSTextField *)FindView(root, @"shortcut-panel-status");
    NSTextField *feedback = (NSTextField *)FindView(root, @"shortcut-feedback");
    NSTextField *privacy = (NSTextField *)FindView(root, @"local-processing");
    NSSwitch *selectionEnabled = (NSSwitch *)FindView(root, @"shortcut-selection-enabled");
    NSSwitch *panelEnabled = (NSSwitch *)FindView(root, @"shortcut-panel-enabled");
    NSButton *selectionKey = (NSButton *)FindView(root, @"shortcut-selection-key");
    NSButton *panelKey = (NSButton *)FindView(root, @"shortcut-panel-key");
    NSPopUpButton *selectionCount = (NSPopUpButton *)FindView(root, @"shortcut-selection-count");
    NSString *privacyText = privacy.stringValue;
    Require(selectionEnabled.state == NSControlStateValueOn && panelEnabled.state == NSControlStateValueOn &&
        selectionCount.indexOfSelectedItem == 1 &&
        [selectionKey.title isEqualToString:ShortcutKeyLabel(lore::defaultShortcuts()[0])] &&
        [panelKey.title isEqualToString:ShortcutKeyLabel(lore::defaultShortcuts()[1])],
        @"Both shortcuts must show their enabled defaults and separate press counts");
    __block NSUInteger loginSettings = 0, loginChanges = 0;
    __block BOOL requestedLogin = NO;
    settings.onLoginSettings = ^{ ++loginSettings; };
    settings.onLoginChanged = ^(BOOL enabled) { ++loginChanges; requestedLogin = enabled; };
    [(NSButton *)FindView(root, @"shortcut-selection-permission") performClick:nil];
    Require(monitor.permissionRequests == 1 && monitor.lastPermissionAction == lore::ShortcutAction::TranslateSelection,
        @"Selection permission action must reach its own monitor action");
    [(NSButton *)FindView(root, @"shortcut-panel-permission") performClick:nil];
    Require(monitor.permissionRequests == 2 && monitor.lastPermissionAction == lore::ShortcutAction::OpenPanel,
        @"Panel permission action must reach its own monitor action");
    [(NSButton *)FindView(root, @"login-items") performClick:nil];
    login.state = NSControlStateValueOn;
    SendControlAction(login);
    Require(loginSettings == 1 && loginChanges == 1 && requestedLogin,
        @"Login actions must forward exactly once without changing system services");

    [settings setLoginStatus:SMAppServiceStatusNotRegistered message:nil error:NO];
    Require(login.state == NSControlStateValueOff && hint.hidden,
        @"Unregistered login service must show off without a stale message");
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    Require([selectionStatus.stringValue isEqualToString:@"Input Monitoring required"] &&
        [panelStatus.stringValue isEqualToString:@"Accessibility required"],
        @"Each shortcut must explain its own missing permission");
    RequireTintInBothAppearances(window, selectionStatus.textColor, LoreColor(LoreWarning),
        @"Input Monitoring permission must use the shared warning color");
    RequireTintInBothAppearances(window, panelStatus.textColor, LoreColor(LoreWarning),
        @"Accessibility permission must use the same warning color");
    CheckInputFaces(window);
    Capture(window, @"light");
    CGFloat baseHeight = root.bounds.size.height;
    [settings setLoginStatus:SMAppServiceStatusRequiresApproval message:nil error:NO];
    Require(login.state == NSControlStateValueOn && !hint.hidden && hint.stringValue.length > 0,
        @"Pending approval must remain on with an explanatory message");
    Capture(window, @"approval");
    [settings setLoginStatus:SMAppServiceStatusEnabled message:nil error:NO];
    Require(login.state == NSControlStateValueOn && hint.hidden,
        @"Enabled service must show on and clear approval feedback");
    monitor.selectionAvailability = ShortcutAvailabilityAvailable;
    monitor.panelAvailability = ShortcutAvailabilityAvailable;
    [settings refresh];
    Require([selectionStatus.stringValue isEqualToString:@"Shortcut ready"] &&
        [panelStatus.stringValue isEqualToString:@"Shortcut ready"], @"Active shortcuts must show ready");
    RequireTintInBothAppearances(window, selectionStatus.textColor, LoreColor(LoreSuccess),
        @"Ready shortcuts must use the shared success color");
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    Capture(window, @"dark");
    CGFloat darkBrightness = BackgroundBrightness(window);
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    Require(BackgroundBrightness(window) > darkBrightness + 0.3,
            @"Changing appearance on visible settings must repaint its paper background");
    monitor.panelAvailability = ShortcutAvailabilityFailed;
    [settings refresh];
    Require([panelStatus.stringValue isEqualToString:@"Could not start monitoring"] &&
        !FindView(root, @"shortcut-panel-permission").hidden,
        @"A failed shortcut needs its own status and retry action");
    RequireTintInBothAppearances(window, panelStatus.textColor, LoreColor(LoreError),
        @"Failed shortcuts must use the same error color as translation failures");
    monitor.panelAvailability = ShortcutAvailabilityAvailable;
    [settings refresh];

    NSString *longError = @"Lore could not change the launch-at-login setting. The operating system returned an error while updating this application’s registration. Open Login Items in System Settings, review the current permissions, and try again.";
    [settings setLoginStatus:SMAppServiceStatusNotRegistered message:longError error:YES];
    CheckBounds(window);
    Require(login.state == NSControlStateValueOff && !hint.hidden && [hint.stringValue isEqualToString:longError],
        @"Failed changes must restore the actual login state and retain the full error");
    RequireTintInBothAppearances(window, hint.textColor, LoreColor(LoreError),
        @"Login failures must use the common error color");
    NSRect textBounds = [hint.attributedStringValue boundingRectWithSize:NSMakeSize(hint.bounds.size.width, CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading];
    Require(root.bounds.size.height > baseHeight && hint.bounds.size.height + 2 >= textBounds.size.height,
        @"Long login errors must wrap and grow the window rather than clip");
    Require([privacy.stringValue isEqualToString:privacyText], @"Login feedback must preserve the privacy explanation");
    Capture(window, @"long-error");
    [settings setLoginStatus:SMAppServiceStatusNotRegistered message:nil error:NO];
    Settle(window);
    Require(hint.hidden && root.bounds.size.height <= baseHeight + 1,
        @"Clearing feedback must restore the compact settings height");

    selectionEnabled.state = NSControlStateValueOff;
    SendControlAction(selectionEnabled);
    Require(![preferences bindingForAction:lore::ShortcutAction::TranslateSelection].enabled &&
        [preferences bindingForAction:lore::ShortcutAction::OpenPanel].enabled &&
        [selectionStatus.stringValue isEqualToString:@"Off"], @"Disabling one action must preserve the other");
    RequireTintInBothAppearances(window, feedback.textColor, LoreColor(LoreSecondaryText),
        @"Saved settings must use informational feedback rather than error styling");
    [selectionCount selectItemAtIndex:0];
    SendControlAction(selectionCount);
    Require([preferences bindingForAction:lore::ShortcutAction::TranslateSelection].pressCount == 1,
        @"A disabled action must still allow changing its press count");

    [panelKey performClick:nil];
    Require([selectionStatus.stringValue isEqualToString:@"Off"] &&
        [panelStatus.stringValue isEqualToString:@"Recording shortcut…"],
        @"Recording another shortcut must keep an independently disabled row Off");
    [panelKey performClick:nil];
    Require(!monitor.suspended && [panelStatus.stringValue isEqualToString:@"Shortcut ready"],
        @"Canceling an empty recording must restore the enabled row's ready status");

    [selectionKey performClick:nil];
    Require(monitor.suspended && !selectionEnabled.enabled, @"Recording must suspend global shortcuts");
    Require([selectionStatus.stringValue isEqualToString:@"Recording shortcut…"] &&
        [panelStatus.stringValue isEqualToString:@"Paused while recording"],
        @"Recording and paused rows must not claim that shortcuts are ready");
    RequireTintInBothAppearances(window, selectionStatus.textColor, LoreColor(LoreSecondaryText),
        @"Recording status must use neutral feedback rather than success green");
    RequireTintInBothAppearances(window, panelStatus.textColor, LoreColor(LoreSecondaryText),
        @"Paused shortcuts must use neutral feedback rather than success green");
    Capture(window, @"recording");
    SendKey(settings, 17, NSEventModifierFlagOption, YES, @"t");
    Require(monitor.suspended && [preferences bindingForAction:lore::ShortcutAction::TranslateSelection].keyCode == 17,
        @"Recording must save the requested physical key but wait for its release");
    Require([selectionStatus.stringValue isEqualToString:@"Waiting for key release…"] &&
        [panelStatus.stringValue isEqualToString:@"Paused while recording"],
        @"Accepted held keys must show release waiting on the correct row");
    Capture(window, @"release-wait");
    SendKey(settings, 17, NSEventModifierFlagOption, NO, @"t");
    Require(!monitor.suspended && selectionEnabled.enabled, @"Key-up must safely restore monitoring");
    Require([selectionStatus.stringValue isEqualToString:@"Off"] &&
        [panelStatus.stringValue isEqualToString:@"Shortcut ready"],
        @"Key release must restore each row's actual enabled and ready state");
    selectionEnabled.state = NSControlStateValueOn;
    SendControlAction(selectionEnabled);
    Require(![preferences bindingForAction:lore::ShortcutAction::TranslateSelection].enabled &&
        selectionEnabled.state == NSControlStateValueOff && !feedback.hidden,
        @"A conflicting single/double assignment must reject enabling without changing the old setting");

    [selectionKey performClick:nil];
    NSEventModifierFlags customModifiers = NSEventModifierFlagControl | NSEventModifierFlagOption;
    SendKey(settings, 40, customModifiers, YES, @"k");
    Require(monitor.suspended, @"An accepted key must remain suspended until release");
    SendKey(settings, 40, customModifiers, NO, @"k");
    selectionEnabled.state = NSControlStateValueOn;
    SendControlAction(selectionEnabled);
    lore::ShortcutBinding custom = [preferences bindingForAction:lore::ShortcutAction::TranslateSelection];
    Require(custom.enabled && custom.keyCode == 40 && custom.modifiers == (lore::Control | lore::Option) &&
        custom.pressCount == 1 && [selectionKey.title isEqualToString:ShortcutKeyLabel(custom)],
        @"Custom key, press count, enabled state, and visible label must agree");
    ShortcutPreferences *reloaded = [[ShortcutPreferences alloc] initWithDefaults:defaults];
    lore::ShortcutBinding persisted = [reloaded bindingForAction:lore::ShortcutAction::TranslateSelection];
    Require(persisted.enabled && persisted.keyCode == custom.keyCode && persisted.modifiers == custom.modifiers &&
        persisted.pressCount == custom.pressCount, @"Recorded settings must survive reloading preferences");
    Capture(window, @"custom-shortcut");

    [selectionKey performClick:nil];
    SendKey(settings, 12, NSEventModifierFlagCommand, YES, @"q");
    SendKey(settings, 12, NSEventModifierFlagCommand, NO, @"q");
    Require(monitor.suspended && [preferences bindingForAction:lore::ShortcutAction::TranslateSelection].keyCode == 40,
        @"Reserved commands must be consumed without quitting or replacing the old key");
    SendKey(settings, 53, 0, YES, @"\x1b");
    Require(monitor.suspended && window.visible, @"Esc cancels recording without closing or resuming before key-up");
    SendKey(settings, 53, 0, NO, @"\x1b");
    Require(!monitor.suspended && window.visible &&
        [preferences bindingForAction:lore::ShortcutAction::TranslateSelection].keyCode == 40,
        @"Canceling recording must preserve the old assignment and the settings window");

    // Hosted runners can dispatch programmatic control actions without ever
    // granting this accessory app a key window. Exercise the real delegate's
    // focus lifecycle explicitly so orderOut is not an implicit prerequisite.
    id<NSWindowDelegate> delegate = window.delegate;
    [delegate windowDidBecomeKey:[NSNotification notificationWithName:NSWindowDidBecomeKeyNotification object:window]];
    Require(monitor.settingsActive, @"The become-key callback must mark settings active before focus-loss testing");
    [selectionKey performClick:nil];
    SendKey(settings, 0, 0, YES, @"a");
    Require(monitor.suspended, @"An invalid key keeps the recorder active");
    [window orderOut:nil];
    Settle(window);
    [delegate windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:window]];
    Require(monitor.suspended && !monitor.settingsActive,
        @"Focus loss must cancel recording but keep a swallowed held key suspended");
    [settings setRecordedKey:0 down:NO];
    NSDate *releaseDeadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (monitor.suspended && releaseDeadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    Require(!monitor.suspended, [NSString stringWithFormat:
        @"Physical release after focus loss must restore global monitoring (keyWindow=%@, settingsActive=%@, recorderEnabled=%@, feedback=%@)",
        @(window.keyWindow), @(monitor.settingsActive), @(selectionKey.enabled), feedback.stringValue]);
    [settings showSettings];
    [(NSButton *)FindView(root, @"shortcut-selection-reset") performClick:nil];
    lore::ShortcutBinding restored = [preferences bindingForAction:lore::ShortcutAction::TranslateSelection];
    Require(restored.enabled && lore::isPassiveCopy(restored) && selectionCount.indexOfSelectedItem == 1,
        @"Reset restores the default key, press count, and enabled state");
    [settings showError:@""];
    for (NSUInteger iteration = 0; iteration < 20; ++iteration) {
        [settings close];
        [settings showSettings];
        Require(settings.window == window && window.contentView == root,
            @"Closing and reopening must reuse the settings window and view tree");
        CheckBounds(window);
    }
    [window makeFirstResponder:window];
    [window cancelOperation:nil];
    Settle(window);
    Require(!window.visible, @"The Escape responder command must close the settings window");
    [settings showSettings];
    NSEvent *closeKey = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:NSEventModifierFlagCommand timestamp:NSProcessInfo.processInfo.systemUptime
        windowNumber:window.windowNumber context:nil characters:@"w" charactersIgnoringModifiers:@"w"
        isARepeat:NO keyCode:13];
    Require([window performKeyEquivalent:closeKey] && !window.visible,
        @"Command-W must close the settings window");
    [defaults removePersistentDomainForName:suite];
    std::cout << "settings_smoke_complete=true\nreused_window_cycles=20\nshortcut_rows=2\nrecorder_release_and_cancel=true\ncaptures=settings-smoke\n";
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        __block int result = EXIT_FAILURE;
        [NSRunLoop.mainRunLoop performBlock:^{
            @try {
                try { RunSmoke(); result = EXIT_SUCCESS; }
                catch (const std::exception &error) { std::cerr << "Settings smoke failed: " << error.what() << '\n'; }
            } @catch (NSException *exception) {
                std::cerr << "Settings smoke failed: " << exception.reason.UTF8String << '\n';
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
