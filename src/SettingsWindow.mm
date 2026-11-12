#import "SettingsWindow.h"
#import "LoreAppearance.h"
#import <CoreGraphics/CoreGraphics.h>

#include <set>

@interface LoreSettingsWindow : NSWindow
@end

@implementation LoreSettingsWindow
- (void)cancelOperation:(id)sender { [self close]; }
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags modifiers = event.modifierFlags &
        (NSEventModifierFlagCommand | NSEventModifierFlagShift |
         NSEventModifierFlagControl | NSEventModifierFlagOption);
    if (modifiers == NSEventModifierFlagCommand &&
        [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"w"]) {
        [self performClose:nil];
        return YES;
    }
    return [super performKeyEquivalent:event];
}
@end

@interface LoreSettingsPaper : NSView
@end

@implementation LoreSettingsPaper
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    [LoreColor(LoreBackground) setFill];
    NSRectFill(self.bounds);
    LoreDrawPaper(self.bounds);
}
@end

@interface LoreSettingsMasthead : LoreSettingsPaper
@end

@implementation LoreSettingsMasthead
- (void)drawRect:(NSRect)dirtyRect { LoreDrawHeader(self.bounds); }
@end

@interface LoreSettingsMedallion : LoreSettingsPaper
@end

@implementation LoreSettingsMedallion
- (void)drawRect:(NSRect)dirtyRect { LoreDrawMedallion(self.bounds); }
@end

@interface LoreSettingsGroup : NSBox
@end

@implementation LoreSettingsGroup
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.borderColor = LoreColor(LoreBorder);
    self.fillColor = LoreColor(LoreSurface);
    self.needsDisplay = YES;
}
@end

namespace {
NSTextField *Label(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = weight >= NSFontWeightMedium ? LoreLabelFont(size) : LoreBodyFont(size);
    label.textColor = color;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

NSStackView *Stack(NSArray<NSView *> *views, NSUserInterfaceLayoutOrientation orientation, CGFloat spacing) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = orientation;
    stack.alignment = orientation == NSUserInterfaceLayoutOrientationVertical ?
        NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    stack.spacing = spacing;
    stack.detachesHiddenViews = YES;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    return stack;
}

NSImageView *Icon(NSString *name) {
    NSImageView *icon = [[NSImageView alloc] init];
    icon.image = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:17
                                                                                   weight:NSFontWeightMedium]];
    icon.contentTintColor = LoreAccentColor();
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:22].active = YES;
    [icon.heightAnchor constraintEqualToConstant:22].active = YES;
    [icon setAccessibilityElement:NO];
    return icon;
}

NSBox *Group(NSView *content) {
    NSBox *box = [[LoreSettingsGroup alloc] init];
    box.boxType = NSBoxCustom;
    box.titlePosition = NSNoTitle;
    box.borderWidth = 1.5;
    box.borderColor = LoreColor(LoreBorder);
    box.fillColor = LoreColor(LoreSurface);
    box.cornerRadius = 8;
    box.contentViewMargins = NSZeroSize;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    [box.contentView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor constant:18],
        [content.trailingAnchor constraintEqualToAnchor:box.contentView.trailingAnchor constant:-18],
        [content.topAnchor constraintEqualToAnchor:box.contentView.topAnchor constant:18],
        [content.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor constant:-18]
    ]];
    return box;
}

NSString *RowID(NSUInteger index, NSString *control) {
    return [NSString stringWithFormat:@"shortcut-%@-%@", index == 0 ? @"selection" : @"panel", control];
}
} // namespace

@interface SettingsWindow () <NSWindowDelegate> {
    ShortcutPreferences *_preferences;
    ShortcutMonitor *_monitor;
    NSMutableArray<NSSwitch *> *_enabledSwitches;
    NSMutableArray<NSButton *> *_recordButtons;
    NSMutableArray<NSPopUpButton *> *_pressCounts;
    NSMutableArray<NSButton *> *_restoreButtons;
    NSMutableArray<NSTextField *> *_statuses;
    NSMutableArray<NSButton *> *_permissionButtons;
    NSTextField *_shortcutHint;
    NSTextField *_loginHint;
    NSSwitch *_loginSwitch;
    id _preferencesObserver;
    id _activationObserver;
    id _eventMonitor;
    NSTimer *_releaseTimer;
    NSInteger _recordingAction;
    BOOL _finishingRecording;
    std::set<CGKeyCode> _heldKeys;
}
- (void)resizeToFit;
- (void)setShortcutMessage:(NSString *)message error:(BOOL)error;
- (NSEvent *)recordEvent:(NSEvent *)event;
- (void)finishRecording;
- (void)finishRecordingIfReleased;
- (BOOL)isRecordingKeyDown:(CGKeyCode)key;
@end

@implementation SettingsWindow

- (instancetype)initWithPreferences:(ShortcutPreferences *)preferences monitor:(ShortcutMonitor *)monitor {
    NSWindow *window = [[LoreSettingsWindow alloc] initWithContentRect:NSMakeRect(0, 0, 700, 420)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    self = [super initWithWindow:window];
    if (!self) return nil;
    _preferences = preferences;
    _monitor = monitor;
    _recordingAction = NSNotFound;
    _enabledSwitches = [NSMutableArray array];
    _recordButtons = [NSMutableArray array];
    _pressCounts = [NSMutableArray array];
    _restoreButtons = [NSMutableArray array];
    _statuses = [NSMutableArray array];
    _permissionButtons = [NSMutableArray array];
    window.title = @"Lore Settings";
    window.backgroundColor = LoreColor(LoreBackground);
    window.titlebarAppearsTransparent = YES;
    window.releasedWhenClosed = NO;
    window.tabbingMode = NSWindowTabbingModeDisallowed;
    window.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace |
                                NSWindowCollectionBehaviorFullScreenAuxiliary;
    window.delegate = self;
    NSView *root = [[LoreSettingsPaper alloc] initWithFrame:window.contentView.bounds];
    window.contentView = root;
    root.identifier = @"lore-settings";

    LoreSettingsMasthead *masthead = [[LoreSettingsMasthead alloc] init];
    masthead.identifier = @"settings-header";
    masthead.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:masthead];
    LoreSettingsMedallion *mascot = [[LoreSettingsMedallion alloc] init];
    mascot.identifier = @"settings-mascot";
    mascot.translatesAutoresizingMaskIntoConstraints = NO;
    [mascot setAccessibilityElement:NO];
    [masthead addSubview:mascot];
    NSTextField *title = Label(@"Lore", 36, NSFontWeightBold, LoreColor(LoreHeaderText));
    title.font = LoreLogoFont(36);
    NSTextField *subtitle = Label(@"Settings · Shortcuts and startup", 12, NSFontWeightRegular,
                                  LoreColor(LoreHeaderText));
    NSStackView *header = Stack(@[title, subtitle], NSUserInterfaceLayoutOrientationVertical, 0);
    [masthead addSubview:header];

    NSStackView *shortcutTitle = Stack(@[Icon(@"keyboard"),
        Label(@"Global shortcuts", 14, NSFontWeightSemibold, LoreColor(LoreText))],
        NSUserInterfaceLayoutOrientationHorizontal, 10);
    NSStackView *shortcutContent = Stack(@[shortcutTitle], NSUserInterfaceLayoutOrientationVertical, 12);
    for (NSUInteger i = 0; i < 2; ++i) {
        lore::ShortcutAction action = static_cast<lore::ShortcutAction>(i);
        NSTextField *name = Label(ShortcutActionTitle(action), 13, NSFontWeightMedium, LoreColor(LoreText));
        [name.widthAnchor constraintEqualToConstant:128].active = YES;
        NSSwitch *enabled = [[NSSwitch alloc] init];
        enabled.target = self;
        enabled.action = @selector(toggleEnabled:);
        enabled.tag = i;
        enabled.identifier = RowID(i, @"enabled");
        [enabled setAccessibilityLabel:[@"Enable " stringByAppendingString:ShortcutActionTitle(action)]];
        NSButton *record = [NSButton buttonWithTitle:@"" target:self action:@selector(beginRecording:)];
        record.font = LoreLabelFont(13);
        record.bezelColor = LoreColor(LoreButton);
        record.contentTintColor = LoreColor(LoreText);
        record.tag = i;
        record.identifier = RowID(i, @"key");
        record.toolTip = @"Click, then press a new key combination once. Set Once or Twice separately. Esc cancels.";
        [record.widthAnchor constraintEqualToConstant:140].active = YES;
        [record setAccessibilityLabel:[ShortcutActionTitle(action) stringByAppendingString:@" shortcut key"]];
        NSPopUpButton *count = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [count addItemsWithTitles:@[@"Once", @"Twice"]];
        count.font = LoreBodyFont(12);
        count.target = self;
        count.action = @selector(changePressCount:);
        count.tag = i;
        count.identifier = RowID(i, @"count");
        count.toolTip = @"For Twice, release the key between presses and press again within 400 ms.";
        [count.widthAnchor constraintEqualToConstant:84].active = YES;
        [count setAccessibilityLabel:[ShortcutActionTitle(action) stringByAppendingString:@" press count"]];
        NSImage *restoreImage = [NSImage imageWithSystemSymbolName:@"arrow.counterclockwise" accessibilityDescription:nil];
        NSButton *restore = [NSButton buttonWithImage:restoreImage target:self action:@selector(restoreShortcut:)];
        restore.tag = i;
        restore.identifier = RowID(i, @"reset");
        restore.bordered = NO;
        restore.contentTintColor = LoreAccentColor();
        restore.toolTip = @"Restore the default key, press count, and enabled state.";
        [restore.widthAnchor constraintEqualToConstant:28].active = YES;
        [restore setAccessibilityLabel:[@"Restore defaults for " stringByAppendingString:ShortcutActionTitle(action)]];
        NSStackView *controls = Stack(@[name, enabled, record, count, restore], NSUserInterfaceLayoutOrientationHorizontal, 8);
        NSTextField *status = Label(@"", 12, NSFontWeightMedium, LoreColor(LoreSecondaryText));
        status.identifier = RowID(i, @"status");
        [status setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSButton *permission = [NSButton buttonWithTitle:@"" target:self action:@selector(requestPermission:)];
        permission.tag = i;
        permission.identifier = RowID(i, @"permission");
        permission.bordered = NO;
        permission.font = LoreLabelFont(12);
        permission.contentTintColor = LoreAccentColor();
        NSView *spacer = [[NSView alloc] init];
        NSStackView *state = Stack(@[status, spacer, permission], NSUserInterfaceLayoutOrientationHorizontal, 10);
        NSStackView *row = Stack(@[controls, state], NSUserInterfaceLayoutOrientationVertical, 4);
        [controls.widthAnchor constraintEqualToAnchor:row.widthAnchor].active = YES;
        [state.widthAnchor constraintEqualToAnchor:row.widthAnchor].active = YES;
        [shortcutContent addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:shortcutContent.widthAnchor].active = YES;
        [_enabledSwitches addObject:enabled];
        [_recordButtons addObject:record];
        [_pressCounts addObject:count];
        [_restoreButtons addObject:restore];
        [_statuses addObject:status];
        [_permissionButtons addObject:permission];
    }
    NSTextField *reservation = Label(@"Except for selection translation with ⌘C twice, enabled keys are reserved for Lore—even a single press. Other apps’ shortcuts cannot be checked automatically.",
        12, NSFontWeightRegular, LoreColor(LoreSecondaryText));
    reservation.identifier = @"shortcut-reservation";
    NSTextField *localKeys = Label(@"In Lore: ⌘Return to translate · ⌘⇧C to copy translation · Esc to close",
        12, NSFontWeightRegular, LoreColor(LoreSecondaryText));
    localKeys.identifier = @"shortcut-local-keys";
    _shortcutHint = Label(@"", 12, NSFontWeightRegular, LoreColor(LoreSecondaryText));
    _shortcutHint.identifier = @"shortcut-feedback";
    _shortcutHint.hidden = YES;
    for (NSTextField *label in @[reservation, localKeys, _shortcutHint]) {
        [shortcutContent addArrangedSubview:label];
        [label.widthAnchor constraintEqualToAnchor:shortcutContent.widthAnchor].active = YES;
    }
    NSBox *shortcutGroup = Group(shortcutContent);
    shortcutGroup.identifier = @"shortcut-group";

    _loginSwitch = [[NSSwitch alloc] init];
    _loginSwitch.target = self;
    _loginSwitch.action = @selector(changeLogin:);
    _loginSwitch.identifier = @"launch-at-login";
    [_loginSwitch setAccessibilityLabel:@"Launch Lore at login"];
    NSView *loginSpacer = [[NSView alloc] init];
    NSStackView *loginTitle = Stack(@[Icon(@"power"),
        Label(@"Launch at login", 14, NSFontWeightSemibold, LoreColor(LoreText)), loginSpacer, _loginSwitch],
        NSUserInterfaceLayoutOrientationHorizontal, 10);
    NSTextField *loginDescription = Label(@"Open Lore automatically when you sign in.",
        13, NSFontWeightRegular, LoreColor(LoreSecondaryText));
    NSButton *loginSettings = [NSButton buttonWithTitle:@"Login Items…" target:self action:@selector(openLoginSettings:)];
    loginSettings.identifier = @"login-items";
    loginSettings.bordered = NO;
    loginSettings.font = LoreLabelFont(12);
    loginSettings.contentTintColor = LoreAccentColor();
    loginSettings.alignment = NSTextAlignmentLeft;
    [loginSettings setAccessibilityLabel:@"Open Login Items settings"];
    _loginHint = Label(@"", 12, NSFontWeightRegular, LoreColor(LoreSecondaryText));
    _loginHint.identifier = @"login-hint";
    _loginHint.hidden = YES;
    NSStackView *loginContent = Stack(@[loginTitle, loginDescription, loginSettings, _loginHint],
        NSUserInterfaceLayoutOrientationVertical, 10);
    NSBox *loginGroup = Group(loginContent);
    loginGroup.identifier = @"login-group";
    for (NSView *view in @[loginTitle, loginDescription, _loginHint]) {
        [view.widthAnchor constraintEqualToAnchor:loginContent.widthAnchor].active = YES;
    }
    NSImageView *privacyIcon = Icon(@"lock.shield");
    privacyIcon.contentTintColor = LoreColor(LoreSecondaryText);
    NSTextField *privacy = Label(@"Translation runs locally on your Mac.",
        12, NSFontWeightRegular, LoreColor(LoreSecondaryText));
    privacy.identifier = @"local-processing";
    NSStackView *footer = Stack(@[privacyIcon, privacy], NSUserInterfaceLayoutOrientationHorizontal, 8);
    NSStackView *content = Stack(@[shortcutGroup, loginGroup, footer],
        NSUserInterfaceLayoutOrientationVertical, 16);
    [root addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [masthead.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [masthead.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [masthead.topAnchor constraintEqualToAnchor:root.topAnchor],
        [masthead.heightAnchor constraintEqualToConstant:80],
        [mascot.leadingAnchor constraintEqualToAnchor:masthead.leadingAnchor constant:24],
        [mascot.centerYAnchor constraintEqualToAnchor:masthead.centerYAnchor],
        [mascot.widthAnchor constraintEqualToConstant:56],
        [mascot.heightAnchor constraintEqualToConstant:56],
        [header.leadingAnchor constraintEqualToAnchor:mascot.trailingAnchor constant:14],
        [header.trailingAnchor constraintLessThanOrEqualToAnchor:masthead.trailingAnchor constant:-24],
        [header.centerYAnchor constraintEqualToAnchor:masthead.centerYAnchor],
        [content.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:24],
        [content.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24],
        [content.topAnchor constraintEqualToAnchor:masthead.bottomAnchor constant:24],
        [content.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-24],
        [shortcutGroup.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [loginGroup.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [footer.widthAnchor constraintEqualToAnchor:content.widthAnchor]
    ]];
    __weak SettingsWindow *weakSelf = self;
    _preferencesObserver = [NSNotificationCenter.defaultCenter addObserverForName:LoreShortcutsDidChangeNotification
        object:preferences queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [weakSelf refresh]; }];
    _activationObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidBecomeActiveNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            SettingsWindow *owner = weakSelf;
            if (!owner) return;
            [owner->_monitor refresh];
            [owner refresh];
        }];
    [self refresh];
    [window center];
    return self;
}

- (void)resizeToFit {
    NSView *root = self.window.contentView;
    [root layoutSubtreeIfNeeded];
    CGFloat height = root.fittingSize.height;
    NSRect frame = self.window.frame;
    CGFloat previousHeight = frame.size.height;
    frame.size.height = [self.window frameRectForContentRect:NSMakeRect(0, 0, 700, height)].size.height;
    frame.origin.y += previousHeight - frame.size.height;
    [self.window setFrame:frame display:YES];
}

- (void)showSettings {
    [_monitor refresh];
    [self refresh];
    [NSApp activateIgnoringOtherApps:YES];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)refresh {
    BOOL recording = _eventMonitor != nil;
    for (NSUInteger i = 0; i < 2; ++i) {
        lore::ShortcutAction action = static_cast<lore::ShortcutAction>(i);
        lore::ShortcutBinding binding = [_preferences bindingForAction:action];
        _enabledSwitches[i].state = binding.enabled ? NSControlStateValueOn : NSControlStateValueOff;
        _enabledSwitches[i].enabled = !recording;
        _recordButtons[i].title = _recordingAction == static_cast<NSInteger>(i) ? @"Press keys…" : ShortcutKeyLabel(binding);
        _recordButtons[i].enabled = !_finishingRecording && (!recording || _recordingAction == static_cast<NSInteger>(i));
        [_pressCounts[i] selectItemAtIndex:binding.pressCount - 1];
        _pressCounts[i].enabled = !recording;
        _restoreButtons[i].enabled = !recording;
        ShortcutAvailability availability = [_monitor availabilityForAction:action];
        NSString *status = @"Off";
        NSString *permission = @"Retry";
        switch (availability) {
            case ShortcutAvailabilityOff: break;
            case ShortcutAvailabilityAvailable: status = @"Shortcut ready"; break;
            case ShortcutAvailabilityNeedsInputMonitoring: status = @"Input Monitoring required"; permission = @"Input Monitoring…"; break;
            case ShortcutAvailabilityNeedsAccessibility: status = @"Accessibility required"; permission = @"Accessibility…"; break;
            case ShortcutAvailabilityFailed: status = @"Could not start monitoring"; break;
        }
        _statuses[i].stringValue = status;
        _statuses[i].textColor = availability == ShortcutAvailabilityAvailable ? LoreColor(LoreSuccess) :
            availability == ShortcutAvailabilityFailed ? LoreColor(LoreError) : LoreColor(LoreSecondaryText);
        _permissionButtons[i].title = permission;
        [_permissionButtons[i] setAccessibilityLabel:[permission stringByAppendingFormat:@" for %@", ShortcutActionTitle(action)]];
        _permissionButtons[i].hidden = availability == ShortcutAvailabilityOff || availability == ShortcutAvailabilityAvailable;
        _permissionButtons[i].enabled = !recording;
    }
    [self resizeToFit];
}

- (void)setShortcutMessage:(NSString *)message error:(BOOL)error {
    _shortcutHint.stringValue = message;
    _shortcutHint.textColor = error ? LoreColor(LoreError) : LoreColor(LoreSecondaryText);
    _shortcutHint.hidden = message.length == 0;
    [self resizeToFit];
}

- (void)showError:(NSString *)message {
    [self showSettings];
    [self setShortcutMessage:message error:YES];
}

- (void)toggleEnabled:(NSSwitch *)sender {
    lore::ShortcutAction action = static_cast<lore::ShortcutAction>(sender.tag);
    lore::ShortcutBinding binding = [_preferences bindingForAction:action];
    binding.enabled = sender.state == NSControlStateValueOn;
    NSString *error = nil;
    BOOL saved = [_preferences setBinding:binding forAction:action error:&error];
    [self setShortcutMessage:saved ? @"Shortcut settings saved." : error ?: @"Could not change this shortcut." error:!saved];
    [self refresh];
}

- (void)changePressCount:(NSPopUpButton *)sender {
    lore::ShortcutAction action = static_cast<lore::ShortcutAction>(sender.tag);
    lore::ShortcutBinding binding = [_preferences bindingForAction:action];
    binding.pressCount = sender.indexOfSelectedItem + 1;
    NSString *error = nil;
    BOOL saved = [_preferences setBinding:binding forAction:action error:&error];
    [self setShortcutMessage:saved ? @"Press count saved." : error ?: @"Could not change the press count." error:!saved];
    [self refresh];
}

- (void)restoreShortcut:(NSButton *)sender {
    NSString *error = nil;
    BOOL saved = [_preferences restoreAction:static_cast<lore::ShortcutAction>(sender.tag) error:&error];
    [self setShortcutMessage:saved ? @"Default key, press count, and enabled state restored." :
        error ?: @"Could not restore defaults." error:!saved];
    [self refresh];
}

- (void)requestPermission:(NSButton *)sender {
    [_monitor requestPermissionForAction:static_cast<lore::ShortcutAction>(sender.tag)];
    [self refresh];
}

- (void)beginRecording:(NSButton *)sender {
    if (_eventMonitor) {
        [self setShortcutMessage:@"Shortcut recording canceled." error:NO];
        [self finishRecording];
        return;
    }
    _recordingAction = sender.tag;
    _finishingRecording = NO;
    _heldKeys.clear();
    _monitor.suspended = YES;
    __weak SettingsWindow *weakSelf = self;
    _eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:
        NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged handler:^NSEvent *(NSEvent *event) {
            SettingsWindow *owner = weakSelf;
            return owner ? [owner recordEvent:event] : event;
        }];
    [self setShortcutMessage:@"Press a key combination with ⌘, ⌃ or ⌥. Press Esc to cancel." error:NO];
    [self refresh];
}

- (NSEvent *)recordEvent:(NSEvent *)event {
    if (event.type == NSEventTypeFlagsChanged) return nil;
    if (event.type == NSEventTypeKeyUp) {
        _heldKeys.erase(event.keyCode);
        if (_finishingRecording) [self finishRecordingIfReleased];
        return nil;
    }
    if (event.type != NSEventTypeKeyDown) return event;
    _heldKeys.insert(event.keyCode);
    if (_finishingRecording || event.isARepeat) return nil;
    std::uint8_t modifiers = ShortcutModifiersFromFlags(event.modifierFlags, event.keyCode);
    if (event.keyCode == 53 && modifiers == 0) {
        [self setShortcutMessage:@"Shortcut recording canceled." error:NO];
        [self finishRecording];
        return nil;
    }
    lore::ShortcutAction action = static_cast<lore::ShortcutAction>(_recordingAction);
    lore::ShortcutBinding binding = [_preferences bindingForAction:action];
    binding.keyCode = event.keyCode;
    binding.modifiers = modifiers;
    NSString *error = nil;
    if (![_preferences setBinding:binding forAction:action error:&error]) {
        [self setShortcutMessage:error ?: @"This shortcut is unavailable. Try a different combination." error:YES];
        return nil;
    }
    [self setShortcutMessage:@"Shortcut saved. Release the key to resume global shortcuts." error:NO];
    [self finishRecording];
    return nil;
}

- (void)finishRecording {
    if (!_eventMonitor) return;
    _recordingAction = NSNotFound;
    _finishingRecording = YES;
    // Key-up may go to another app after focus loss; never restart a global
    // listener while one of the recorder's swallowed keys remains down.
    if (!_releaseTimer) {
        __weak SettingsWindow *weakSelf = self;
        _releaseTimer = [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *timer) {
            [weakSelf finishRecordingIfReleased];
        }];
        [NSRunLoop.mainRunLoop addTimer:_releaseTimer forMode:NSRunLoopCommonModes];
    }
    [self finishRecordingIfReleased];
    [self refresh];
}

- (BOOL)isRecordingKeyDown:(CGKeyCode)key {
    return CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, key);
}

- (void)finishRecordingIfReleased {
    if (!_finishingRecording) return;
    for (auto it = _heldKeys.begin(); it != _heldKeys.end();) {
        if (![self isRecordingKeyDown:*it]) it = _heldKeys.erase(it);
        else ++it;
    }
    if (!_heldKeys.empty()) return;
    [_releaseTimer invalidate];
    _releaseTimer = nil;
    [NSEvent removeMonitor:_eventMonitor];
    _eventMonitor = nil;
    _finishingRecording = NO;
    _monitor.suspended = NO;
    [self refresh];
}

- (void)setLoginStatus:(SMAppServiceStatus)status message:(NSString *)message error:(BOOL)error {
    _loginSwitch.state = status == SMAppServiceStatusEnabled || status == SMAppServiceStatusRequiresApproval ?
        NSControlStateValueOn : NSControlStateValueOff;
    NSString *hint = message ?: (status == SMAppServiceStatusRequiresApproval ?
        @"Allow Lore in System Settings → General → Login Items." : @"");
    _loginHint.stringValue = hint;
    _loginHint.textColor = error ? LoreColor(LoreError) : LoreColor(LoreSecondaryText);
    _loginHint.hidden = hint.length == 0;
    [self resizeToFit];
}

- (void)openLoginSettings:(id)sender { if (self.onLoginSettings) self.onLoginSettings(); }
- (void)changeLogin:(NSSwitch *)sender {
    if (self.onLoginChanged) self.onLoginChanged(sender.state == NSControlStateValueOn);
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    _monitor.settingsActive = YES;
    [_monitor refresh];
    [self refresh];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    _monitor.settingsActive = NO;
    [self finishRecording];
}

- (void)windowWillClose:(NSNotification *)notification {
    _monitor.settingsActive = NO;
    [self finishRecording];
}

- (void)dealloc {
    [_releaseTimer invalidate];
    if (_eventMonitor) {
        [NSEvent removeMonitor:_eventMonitor];
        _monitor.suspended = NO;
    }
    _monitor.settingsActive = NO;
    if (_preferencesObserver) [NSNotificationCenter.defaultCenter removeObserver:_preferencesObserver];
    if (_activationObserver) [NSNotificationCenter.defaultCenter removeObserver:_activationObserver];
}
@end
