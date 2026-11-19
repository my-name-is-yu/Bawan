#import "SettingsViewController.h"
#import "BawanAppearance.h"
#import "SetupUI.h"
#import "BawanChrome.h"
#import "BawanMascotView.h"
#import <CoreGraphics/CoreGraphics.h>

#include <algorithm>
#include <cmath>
#include <set>
#include <vector>

@interface BawanShortcutButton : BawanBorderlessButton
@end

@implementation BawanShortcutButton
- (NSBezierPath *)bawanFocusRingPath { return BawanInputPath(self.bounds); }
- (void)drawRect:(NSRect)dirtyRect {
    BawanDrawInputSurface(self.bounds, self.enabled, self.cell.highlighted);
    [super drawRect:dirtyRect];
}
@end

@interface BawanShortcutPressCount : NSPopUpButton
@end

@implementation BawanShortcutPressCount
BAWAN_BORDERLESS_CONTROL_METHODS(BawanInputPath(self.bounds))
- (void)drawRect:(NSRect)dirtyRect {
    BawanDrawInputSurface(self.bounds, self.enabled, self.cell.highlighted);
    [super drawRect:dirtyRect];
}
@end

namespace {
NSString *RowID(bawan::ShortcutAction action, NSString *control) {
    return [NSString stringWithFormat:@"shortcut-%@-%@", ShortcutSlug(action), control];
}

struct SettingsShortcutRow {
    bawan::ShortcutAction action;
    NSButton *enabled;
    NSButton *record;
    NSPopUpButton *pressCount;
    NSButton *restore;
    NSTextField *status;
    NSButton *permission;
};
}

@interface SettingsViewController () {
    ShortcutPreferences *_preferences;
    ShortcutMonitor *_monitor;
    std::vector<SettingsShortcutRow> _shortcutRows;
    NSTextField *_reservation;
    NSTextField *_shortcutHint;
    NSTextField *_loginHint;
    NSButton *_loginSwitch;
    NSButton *_loginSettings;
    NSButton *_back;
    NSScrollView *_scroll;
    NSTextField *_modelStatus;
    NSTextField *_modelHint;
    BawanModelSetupPhase _modelPhase;
    NSProgressIndicator *_modelProgress;
    NSButton *_modelSetup;
    NSImageView *_modelIcon;
    BawanMascotView *_mascot;
    id _eventMonitor;
    NSTimer *_releaseTimer;
    NSInteger _recordingAction;
    BOOL _finishingRecording;
    BOOL _active;
    std::set<CGKeyCode> _heldKeys;
}
- (void)updateDocumentLayout;
- (void)setShortcutMessage:(NSString *)message error:(BOOL)error;
- (void)revealMessage:(NSTextField *)label;
- (NSEvent *)recordEvent:(NSEvent *)event;
- (void)finishRecording;
- (void)finishRecordingIfReleased;
- (void)updateModelProgressAnimation;
- (BOOL)isRecordingKeyDown:(CGKeyCode)key;
@end

@implementation SettingsViewController

- (instancetype)initWithPreferences:(ShortcutPreferences *)preferences monitor:(ShortcutMonitor *)monitor {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _preferences = preferences;
    _monitor = monitor;
    _recordingAction = NSNotFound;
    BawanSurfaceView *root = BawanMakeWindowSurface(@"bawan-settings", NSMakeRect(0, 0, 720, 500));
    self.view = root;

    BawanChromeHeader header = BawanAddHeader(root, @"settings-header", @"settings-mascot");
    _mascot = header.mascot;
    // The gear sits where the translator's gear opens Settings, and closes it again.
    BawanActionButton *close = BawanAddHeaderButton(header.header, @"settings-close", @"gearshape.fill",
        @"Back to translator", self, @selector(goBack:));
    close.toolTip = @"Back to translator (Esc)";
    BawanChromeFooter footer = BawanAddFooter(root, @"settings-footer");
    _back = BawanAddFooterPrimary(footer.footer, @"settings-back", @"Done  ⌘↵", self, @selector(goBack:));
    _back.toolTip = @"Back to translator (⌘Return or Esc)";
    [_back setAccessibilityLabel:@"Back to translator"];
    BawanAddFooterHint(footer.footer, @"local-processing",
        @"Shortcut permissions do not affect typing or pasting.", _back, nil);

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.identifier = @"settings-scroll";
    _scroll = scroll;
    scroll.borderType = NSNoBorder;
    BawanConfigurePaperScrollView(scroll);
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:scroll];
    BawanSetupDocument *document = [[BawanSetupDocument alloc] initWithFrame:NSZeroRect];
    document.identifier = @"settings-document";
    document.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = document;

    NSTextField *heading = BawanSetupHeading(@"Shortcuts", BawanSetupSectionSize);
    heading.identifier = @"shortcut-heading";
    NSButton *help = [NSButton buttonWithImage:BawanSymbol(@"questionmark.circle", nil, 17)
        target:self action:@selector(showShortcutHelp:)];
    help.identifier = @"shortcut-help";
    help.bordered = NO;
    help.contentTintColor = BawanAccentColor();
    help.translatesAutoresizingMaskIntoConstraints = NO;
    help.toolTip = @"Shortcut help";
    [help setAccessibilityLabel:@"Shortcut help"];
    [help.widthAnchor constraintEqualToConstant:28].active = YES;
    [help.heightAnchor constraintEqualToConstant:28].active = YES;
    NSStackView *headingRow = BawanSetupStack(@[heading, [[NSView alloc] init], help],
        NSUserInterfaceLayoutOrientationHorizontal, 8);
    NSMutableArray<NSView *> *shortcutRows = [NSMutableArray array];
    for (bawan::ShortcutAction action : BawanShortcutActions) {
        const auto actionTag = static_cast<NSInteger>(action);
        BawanCheckbox *enabled = [[BawanCheckbox alloc] initWithFrame:NSZeroRect];
        enabled.title = ShortcutActionTitle(action);
        enabled.target = self;
        enabled.action = @selector(toggleEnabled:);
        enabled.tag = actionTag;
        enabled.identifier = RowID(action, @"enabled");
        [enabled setAccessibilityLabel:[@"Use shortcut for " stringByAppendingString:ShortcutActionTitle(action)]];
        NSButton *record = [[BawanShortcutButton alloc] initWithFrame:NSZeroRect];
        record.target = self;
        record.action = @selector(beginRecording:);
        [record setButtonType:NSButtonTypeMomentaryPushIn];
        record.title = @"";
        record.bordered = NO;
        record.focusRingType = NSFocusRingTypeExterior;
        record.font = BawanLabelFont(BawanInputFontSize);
        record.contentTintColor = BawanColor(BawanText);
        record.translatesAutoresizingMaskIntoConstraints = NO;
        record.tag = actionTag;
        record.identifier = RowID(action, @"key");
        record.toolTip = @"Click, then press a new key combination once. Set Once or Twice separately. Esc cancels.";
        [record.widthAnchor constraintEqualToConstant:BawanSetupKeyWidth].active = YES;
        [record.heightAnchor constraintEqualToConstant:BawanInputHeight].active = YES;
        [record setAccessibilityLabel:[ShortcutActionTitle(action) stringByAppendingString:@" shortcut key"]];
        NSPopUpButton *count = [[BawanShortcutPressCount alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [count addItemsWithTitles:@[ShortcutPressCountTitle(1), ShortcutPressCountTitle(2)]];
        count.bordered = NO;
        count.focusRingType = NSFocusRingTypeExterior;
        count.font = BawanLabelFont(BawanInputFontSize);
        count.contentTintColor = BawanColor(BawanText);
        count.translatesAutoresizingMaskIntoConstraints = NO;
        count.target = self;
        count.action = @selector(changePressCount:);
        count.tag = actionTag;
        count.identifier = RowID(action, @"count");
        count.toolTip = @"For Twice, release the key between presses and press again within 400 ms.";
        [count.widthAnchor constraintEqualToConstant:BawanSetupCountWidth].active = YES;
        [count.heightAnchor constraintEqualToConstant:BawanInputHeight].active = YES;
        [count setAccessibilityLabel:[ShortcutActionTitle(action) stringByAppendingString:@" press count"]];
        NSButton *restore = [NSButton buttonWithImage:BawanSymbol(@"arrow.counterclockwise", nil, 15)
            target:self action:@selector(restoreShortcut:)];
        restore.translatesAutoresizingMaskIntoConstraints = NO;
        restore.tag = actionTag;
        restore.identifier = RowID(action, @"reset");
        restore.bordered = NO;
        restore.contentTintColor = BawanAccentColor();
        restore.toolTip = @"Restore the default key, press count, and enabled state.";
        [restore.widthAnchor constraintEqualToConstant:24].active = YES;
        [restore.heightAnchor constraintEqualToConstant:28].active = YES;
        [restore setAccessibilityLabel:[@"Restore defaults for " stringByAppendingString:ShortcutActionTitle(action)]];
        NSTextField *status = BawanLabel(@"", BawanSetupCaptionSize, NSFontWeightRegular, BawanColor(BawanSecondaryText));
        status.identifier = RowID(action, @"status");
        BawanActionButton *permission = BawanSetupButton(RowID(action, @"permission"), @"Set Up…",
            BawanSetupActionWidth, self, @selector(requestPermission:));
        permission.tag = actionTag;
        NSView *row = BawanSetupRow(RowID(action, @"row"), enabled, status, @[record, count, restore, permission]);
        if (shortcutRows.count) [shortcutRows addObject:BawanSetupRule()];
        [shortcutRows addObject:row];
        _shortcutRows.push_back({action, enabled, record, count, restore, status, permission});
    }
    NSStackView *shortcutGroup = BawanSetupStack(shortcutRows, NSUserInterfaceLayoutOrientationVertical, 0);
    shortcutGroup.identifier = @"shortcut-group";
    for (NSView *view in shortcutRows) [view.widthAnchor constraintEqualToAnchor:shortcutGroup.widthAnchor].active = YES;
    _reservation = BawanLabel(@"Custom shortcuts reserve their keys in other apps.",
        BawanSetupCaptionSize, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    _reservation.identifier = @"shortcut-reservation";
    _reservation.hidden = YES;
    _shortcutHint = BawanLabel(@"", BawanSetupCaptionSize, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    _shortcutHint.identifier = @"shortcut-feedback";
    _shortcutHint.hidden = YES;

    NSTextField *general = BawanSetupHeading(@"General", BawanSetupSectionSize);
    general.identifier = @"general-heading";
    _loginSwitch = [[BawanToggle alloc] initWithFrame:NSZeroRect];
    _loginSwitch.target = self;
    _loginSwitch.action = @selector(changeLogin:);
    _loginSwitch.identifier = @"launch-at-login";
    [_loginSwitch setAccessibilityLabel:@"Launch Bawan at login"];
    _loginSettings = BawanSetupButton(@"login-items", @"Login Items…", 112, self, @selector(openLoginSettings:));
    _loginSettings.hidden = YES;
    [_loginSettings setAccessibilityLabel:@"Open Login Items settings"];
    NSTextField *loginTitle = BawanLabel(@"Launch at Login", BawanSetupRowTitleSize, NSFontWeightSemibold,
        BawanColor(BawanText));
    NSTextField *loginDescription = BawanLabel(@"Open Bawan automatically when you sign in.",
        BawanSetupCaptionSize, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    NSView *loginRow = BawanSetupRow(@"login-row", loginTitle, loginDescription, @[_loginSettings, _loginSwitch]);
    _loginHint = BawanLabel(@"", BawanSetupCaptionSize, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    _loginHint.identifier = @"login-hint";
    _loginHint.hidden = YES;
    NSStackView *loginContent = BawanSetupStack(@[loginRow, _loginHint], NSUserInterfaceLayoutOrientationVertical, 4);
    loginContent.identifier = @"login-group";
    [loginRow.widthAnchor constraintEqualToAnchor:loginContent.widthAnchor].active = YES;
    [_loginHint.widthAnchor constraintEqualToAnchor:loginContent.widthAnchor].active = YES;

    _modelIcon = [[NSImageView alloc] init];
    _modelIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [_modelIcon.widthAnchor constraintEqualToConstant:16].active = YES;
    [_modelIcon.heightAnchor constraintEqualToConstant:16].active = YES;
    [_modelIcon setAccessibilityElement:NO];
    NSTextField *modelTitle = BawanLabel(@"Translation Model", BawanSetupRowTitleSize, NSFontWeightSemibold,
        BawanColor(BawanText));
    _modelStatus = BawanLabel(@"", BawanSetupCaptionSize, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    _modelStatus.identifier = @"settings-model-status";
    NSStackView *modelState = BawanSetupStack(@[_modelIcon, _modelStatus], NSUserInterfaceLayoutOrientationHorizontal, 6);
    NSButton *modelLicense = BawanSetupButton(@"settings-model-license", BawanModelLicenseTitle,
        BawanSetupActionWidth + 32, self, @selector(openModelLicense:));
    _modelSetup = BawanSetupButton(@"settings-model-setup", @"", BawanSetupModelActionWidth, self, @selector(prepareModel:));
    NSView *modelRow = BawanSetupRow(@"settings-model-row", modelTitle, modelState, @[_modelSetup, modelLicense]);
    _modelHint = BawanLabel(@"", BawanSetupCaptionSize, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    _modelHint.identifier = @"settings-model-message";
    _modelHint.hidden = YES;
    _modelProgress = [[BawanProgressBar alloc] init];
    _modelProgress.style = NSProgressIndicatorStyleBar;
    _modelProgress.indeterminate = NO;
    _modelProgress.minValue = 0;
    _modelProgress.maxValue = 1;
    _modelProgress.hidden = YES;
    _modelProgress.translatesAutoresizingMaskIntoConstraints = NO;
    _modelProgress.identifier = @"settings-model-progress";
    [_modelProgress setAccessibilityLabel:@"Model setup progress"];
    [_modelProgress.heightAnchor constraintEqualToConstant:8].active = YES;
    NSStackView *modelContent = BawanSetupStack(@[modelRow, _modelHint, _modelProgress],
        NSUserInterfaceLayoutOrientationVertical, 6);
    modelContent.identifier = @"settings-model-group";
    for (NSView *view in @[modelRow, _modelHint, _modelProgress]) {
        [view.widthAnchor constraintEqualToAnchor:modelContent.widthAnchor].active = YES;
    }
    NSStackView *content = BawanSetupStack(@[headingRow, shortcutGroup, _reservation, _shortcutHint,
        general, loginContent, BawanSetupRule(), modelContent],
        NSUserInterfaceLayoutOrientationVertical, 8);
    [content setCustomSpacing:24 afterView:_shortcutHint];
    [content setCustomSpacing:24 afterView:shortcutGroup];
    [content setCustomSpacing:24 afterView:_reservation];
    [document addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:header.header.bottomAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:footer.divider.topAnchor],
        [document.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [document.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [content.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:24],
        [content.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-24],
        [content.topAnchor constraintEqualToAnchor:document.topAnchor constant:24],
        [content.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-24]
    ]];
    for (NSView *view in content.arrangedSubviews) {
        [view.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;
    }
    [self setModelPhase:BawanModelSetupNeedsDownload message:@"" progress:0];
    [self refresh];
    return self;
}

- (void)updateDocumentLayout {
    [self.view layoutSubtreeIfNeeded];
}

- (void)setActive:(BOOL)active {
    _active = active;
    [self updateModelProgressAnimation];
    _monitor.configurationActive = active;
    if (active) {
        [_monitor refresh];
        [self refresh];
    } else {
        [_mascot resetHoverAnimation];
        [self finishRecording];
    }
}

- (void)focusInitialControl {
    BawanSetupPresentPage(self.view, _scroll);
}

- (void)refresh {
    BOOL recording = _eventMonitor != nil;
    BOOL reservesCustomKeys = NO;
    const auto defaults = bawan::defaultShortcuts();
    for (const SettingsShortcutRow &row : _shortcutRows) {
        bawan::ShortcutBinding binding = [_preferences bindingForAction:row.action];
        const auto &defaultBinding = defaults[static_cast<NSUInteger>(row.action)];
        BOOL recordingRow = recording && _recordingAction == static_cast<NSInteger>(row.action);
        row.enabled.state = binding.enabled ? NSControlStateValueOn : NSControlStateValueOff;
        row.enabled.enabled = !recording;
        row.record.title = recordingRow && !_finishingRecording ? @"Press keys…" : ShortcutKeyLabel(binding);
        row.record.enabled = !_finishingRecording && (!recording || recordingRow);
        [row.pressCount selectItemAtIndex:binding.pressCount - 1];
        row.pressCount.enabled = !recording;
        row.restore.enabled = !recording;
        ShortcutAvailability availability = [_monitor availabilityForAction:row.action];
        BOOL custom = binding.keyCode != defaultBinding.keyCode || binding.modifiers != defaultBinding.modifiers ||
                      binding.pressCount != defaultBinding.pressCount;
        reservesCustomKeys |= binding.enabled && custom &&
            (row.action != bawan::ShortcutAction::TranslateSelection || !bawan::isPassiveCopy(binding));
        BawanShortcutPresentation presentation = BawanPresentShortcut(availability);
        NSString *status = presentation.status;
        BawanColorRole statusRole = presentation.color;
        if (recording) {
            status = recordingRow ? (_finishingRecording ? @"Waiting for key release…" : @"Recording shortcut…") :
                (binding.enabled ? @"Paused while recording" : @"Off");
            statusRole = BawanSecondaryText;
        }
        row.status.stringValue = status;
        row.status.textColor = BawanColor(statusRole);
        BawanApplyShortcutAction(row.permission, presentation, ShortcutActionTitle(row.action));
        row.permission.hidden = !presentation.needsAction;
        row.permission.enabled = !recording;
    }
    _reservation.hidden = !reservesCustomKeys;
    [self updateDocumentLayout];
}

- (void)setShortcutMessage:(NSString *)message error:(BOOL)error {
    _shortcutHint.stringValue = message;
    _shortcutHint.textColor = error ? BawanColor(BawanError) : BawanColor(BawanSecondaryText);
    _shortcutHint.hidden = message.length == 0;
    [self updateDocumentLayout];
    if (error && message.length > 0) [self revealMessage:_shortcutHint];
}

- (void)revealMessage:(NSTextField *)label {
    [label scrollRectToVisible:label.bounds];
    if (self.view.window.visible) {
        NSAccessibilityPostNotificationWithUserInfo(NSApp, NSAccessibilityAnnouncementRequestedNotification, @{
            NSAccessibilityAnnouncementKey: label.stringValue,
            NSAccessibilityPriorityKey: @(NSAccessibilityPriorityMedium)
        });
    }
}

- (void)showError:(NSString *)message {
    [self setShortcutMessage:message error:YES];
}

- (void)goBack:(id)sender { if (self.onBack) self.onBack(); }
// ⌘Return could be the combination being recorded, so it only leaves when idle.
- (void)performPrimaryAction { if (!_eventMonitor) [self goBack:nil]; }

- (void)showShortcutHelp:(id)sender {
    NSWindow *window = self.view.window;
    if (!window || window.attachedSheet) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Shortcut help";
    alert.informativeText = @"Click a Shortcut field and press the new combination once, then choose Once or Twice. For Twice, release the key and press it again within 400 ms.\n\n"
        @"Except for Translate Selection with ⌘C twice, enabled shortcuts reserve their keys in other apps, including a single press. Other apps’ shortcuts cannot be checked automatically.\n\n"
        @"In the translator: ⌘Return translates or cancels, ⇧⌘C copies the translation, and Esc closes. In Settings, Esc returns to the translator. While recording, Esc cancels recording first.";
    [alert addButtonWithTitle:@"Done"];
    [alert beginSheetModalForWindow:window completionHandler:nil];
}

- (void)toggleEnabled:(NSButton *)sender {
    bawan::ShortcutAction action = static_cast<bawan::ShortcutAction>(sender.tag);
    bawan::ShortcutBinding binding = [_preferences bindingForAction:action];
    binding.enabled = sender.state == NSControlStateValueOn;
    NSString *error = nil;
    BOOL saved = [_preferences setBinding:binding forAction:action error:&error];
    [self setShortcutMessage:saved ? @"Shortcut settings saved." : error ?: @"Could not change this shortcut." error:!saved];
    [self refresh];
}

- (void)changePressCount:(NSPopUpButton *)sender {
    bawan::ShortcutAction action = static_cast<bawan::ShortcutAction>(sender.tag);
    bawan::ShortcutBinding binding = [_preferences bindingForAction:action];
    binding.pressCount = sender.indexOfSelectedItem + 1;
    NSString *error = nil;
    BOOL saved = [_preferences setBinding:binding forAction:action error:&error];
    [self setShortcutMessage:saved ? @"Press count saved." : error ?: @"Could not change the press count." error:!saved];
    [self refresh];
}

- (void)restoreShortcut:(NSButton *)sender {
    NSString *error = nil;
    BOOL saved = [_preferences restoreAction:static_cast<bawan::ShortcutAction>(sender.tag) error:&error];
    [self setShortcutMessage:saved ? @"Default key, press count, and enabled state restored." :
        error ?: @"Could not restore defaults." error:!saved];
    [self refresh];
}

- (void)requestPermission:(NSButton *)sender {
    [_monitor requestPermissionForAction:static_cast<bawan::ShortcutAction>(sender.tag)];
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
    __weak SettingsViewController *weakSelf = self;
    _eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:
        NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged handler:^NSEvent *(NSEvent *event) {
            SettingsViewController *owner = weakSelf;
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
    bawan::ShortcutAction action = static_cast<bawan::ShortcutAction>(_recordingAction);
    bawan::ShortcutBinding binding = [_preferences bindingForAction:action];
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
    _finishingRecording = YES;
    // Key-up may go to another app after focus loss; never restart a global
    // listener while one of the recorder's swallowed keys remains down.
    if (!_releaseTimer) {
        __weak SettingsViewController *weakSelf = self;
        _releaseTimer = [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(__unused NSTimer *timer) {
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
    _recordingAction = NSNotFound;
    _finishingRecording = NO;
    _monitor.suspended = NO;
    [self refresh];
}

- (void)setLoginStatus:(SMAppServiceStatus)status message:(NSString *)message error:(BOOL)error {
    _loginSwitch.state = status == SMAppServiceStatusEnabled || status == SMAppServiceStatusRequiresApproval ?
        NSControlStateValueOn : NSControlStateValueOff;
    NSString *hint = message ?: (status == SMAppServiceStatusRequiresApproval ?
        @"Allow Bawan in System Settings → General → Login Items." : @"");
    BOOL changed = _loginHint.hidden || ![_loginHint.stringValue isEqualToString:hint];
    _loginHint.stringValue = hint;
    _loginHint.textColor = error ? BawanColor(BawanError) : BawanColor(BawanSecondaryText);
    _loginHint.hidden = hint.length == 0;
    _loginSettings.hidden = !error && status != SMAppServiceStatusRequiresApproval;
    [self updateDocumentLayout];
    if (hint.length > 0 && (error || (changed && status == SMAppServiceStatusRequiresApproval))) {
        [self revealMessage:_loginHint];
    }
}

- (void)setModelPhase:(BawanModelSetupPhase)phase message:(NSString *)message progress:(std::optional<double>)progress {
    BOOL changed = _modelPhase != phase || ![_modelHint.stringValue isEqualToString:message];
    BOOL failed = phase == BawanModelSetupFailed || phase == BawanModelSetupResumableFailure;
    _modelPhase = phase;
    const BawanModelPresentation presentation = BawanPresentModel(phase);
    _modelIcon.image = BawanSymbol(presentation.symbol, nil, 15);
    _modelIcon.contentTintColor = BawanColor(presentation.symbolColor);
    _modelStatus.stringValue = presentation.status;
    _modelStatus.textColor = BawanColor(presentation.statusColor);
    _modelSetup.hidden = presentation.actionTitle.length == 0;
    _modelSetup.title = presentation.actionTitle;
    _modelProgress.hidden = phase != BawanModelSetupPreparing && phase != BawanModelSetupDownloading &&
        phase != BawanModelSetupPaused && phase != BawanModelSetupResumableFailure;
    const bool determinate = progress && std::isfinite(*progress);
    _modelProgress.indeterminate = !determinate;
    _modelProgress.doubleValue = determinate ? std::clamp(*progress, 0.0, 1.0) : 0;
    [self updateModelProgressAnimation];
    _modelHint.stringValue = message;
    _modelHint.hidden = message.length == 0 || phase == BawanModelSetupReady;
    _modelHint.textColor = BawanColor(failed ? BawanError : BawanSecondaryText);
    [self updateDocumentLayout];
    // Refreshing an unchanged snapshot must preserve the user's reading position
    // and must not repeat the accessibility announcement.
    if (changed && failed && message.length) [self revealMessage:_modelHint];
}

- (void)updateModelProgressAnimation {
    if (_active && !_modelProgress.hidden && _modelProgress.indeterminate) [_modelProgress startAnimation:nil];
    else [_modelProgress stopAnimation:nil];
}

- (void)openModelLicense:(id)sender { if (self.onModelLicense) self.onModelLicense(); }
- (void)prepareModel:(id)sender { if (self.onModelSetup) self.onModelSetup(); }

- (void)openLoginSettings:(id)sender { if (self.onLoginSettings) self.onLoginSettings(); }
- (void)changeLogin:(NSButton *)sender {
    if (self.onLoginChanged) self.onLoginChanged(sender.state == NSControlStateValueOn);
}

- (void)dealloc {
    [_modelProgress stopAnimation:nil];
    [_releaseTimer invalidate];
    if (_eventMonitor) {
        [NSEvent removeMonitor:_eventMonitor];
        _monitor.suspended = NO;
    }
    _monitor.configurationActive = NO;
}
@end
