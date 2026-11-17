#import "SettingsViewController.h"
#import "BawanAppearance.h"
#import "SetupUI.h"
#import "BawanMascotView.h"
#import <CoreGraphics/CoreGraphics.h>

#include <algorithm>
#include <cmath>
#include <set>

@interface BawanShortcutButton : NSButton
@end

@implementation BawanShortcutButton
- (NSRect)alignmentRectForFrame:(NSRect)frame { return frame; }
- (NSRect)frameForAlignmentRect:(NSRect)rect { return rect; }
- (NSRect)focusRingMaskBounds { return BawanInputPath(self.bounds).bounds; }
- (void)drawFocusRingMask {
    [BawanInputPath(self.bounds) fill];
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    BawanDrawInputSurface(self.bounds, self.enabled, self.cell.highlighted);
    [super drawRect:dirtyRect];
}
@end

@interface BawanShortcutPressCount : NSPopUpButton
@end

@implementation BawanShortcutPressCount
- (NSRect)alignmentRectForFrame:(NSRect)frame { return frame; }
- (NSRect)frameForAlignmentRect:(NSRect)rect { return rect; }
- (NSRect)focusRingMaskBounds { return BawanInputPath(self.bounds).bounds; }
- (void)drawFocusRingMask {
    [BawanInputPath(self.bounds) fill];
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    BawanDrawInputSurface(self.bounds, self.enabled, self.cell.highlighted);
    [super drawRect:dirtyRect];
}
@end

namespace {
NSBox *Group(NSView *content) {
    BawanSetupGroup *box = [[BawanSetupGroup alloc] init];
    box.boxType = NSBoxCustom;
    box.titlePosition = NSNoTitle;
    box.borderWidth = 1;
    box.borderColor = BawanColor(BawanBorder);
    box.fillColor = BawanColor(BawanSurface);
    box.cornerRadius = 8;
    box.contentViewMargins = NSZeroSize;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    [box.contentView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor constant:14],
        [content.trailingAnchor constraintEqualToAnchor:box.contentView.trailingAnchor constant:-14],
        [content.topAnchor constraintEqualToAnchor:box.contentView.topAnchor constant:14],
        [content.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor constant:-14]
    ]];
    return box;
}

NSString *RowID(NSUInteger index, NSString *control) {
    return [NSString stringWithFormat:@"shortcut-%@-%@", index == 0 ? @"selection" : @"panel", control];
}
}

@interface SettingsViewController () {
    ShortcutPreferences *_preferences;
    ShortcutMonitor *_monitor;
    NSMutableArray<NSButton *> *_enabledButtons;
    NSMutableArray<NSButton *> *_recordButtons;
    NSMutableArray<NSPopUpButton *> *_pressCounts;
    NSMutableArray<NSButton *> *_restoreButtons;
    NSMutableArray<NSTextField *> *_statuses;
    NSMutableArray<NSButton *> *_permissionButtons;
    NSTextField *_reservation;
    NSTextField *_shortcutHint;
    NSTextField *_loginHint;
    NSSwitch *_loginSwitch;
    NSButton *_loginSettings;
    NSButton *_back;
    NSTextField *_modelStatus;
    NSTextField *_modelHint;
    NSProgressIndicator *_modelProgress;
    NSButton *_modelSetup;
    NSImageView *_modelCheck;
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
    _enabledButtons = [NSMutableArray array];
    _recordButtons = [NSMutableArray array];
    _pressCounts = [NSMutableArray array];
    _restoreButtons = [NSMutableArray array];
    _statuses = [NSMutableArray array];
    _permissionButtons = [NSMutableArray array];
    BawanSetupPaper *root = [[BawanSetupPaper alloc] initWithFrame:NSMakeRect(0, 0, 720, 500)];
    self.view = root;
    root.identifier = @"bawan-settings";

    BawanSetupPaper *masthead = [[BawanSetupPaper alloc] init];
    masthead.masthead = YES;
    masthead.identifier = @"settings-header";
    masthead.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:masthead];
    _mascot = [[BawanMascotView alloc] init];
    _mascot.identifier = @"settings-mascot";
    _mascot.translatesAutoresizingMaskIntoConstraints = NO;
    [_mascot setAccessibilityElement:NO];
    [masthead addSubview:_mascot];
    NSTextField *subtitle = BawanSetupLabel(@"Settings", 16, NSFontWeightSemibold, BawanColor(BawanHeaderText));
    subtitle.font = BawanLabelFont(16);
    subtitle.identifier = @"settings-subtitle";
    subtitle.selectable = NO;
    [masthead addSubview:subtitle];
    _back = BawanSetupLink(@"Back to translator", self, @selector(goBack:));
    _back.identifier = @"settings-back";
    _back.contentTintColor = BawanColor(BawanHeaderText);
    _back.image = BawanSymbol(@"chevron.left", nil, 12);
    _back.imagePosition = NSImageLeft;
    _back.imageHugsTitle = YES;
    _back.toolTip = @"Back to translator (Esc)";
    [_back setAccessibilityLabel:@"Back to translator"];
    [masthead addSubview:_back];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.identifier = @"settings-scroll";
    scroll.borderType = NSNoBorder;
    BawanConfigurePaperScrollView(scroll);
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:scroll];
    BawanSetupDocument *document = [[BawanSetupDocument alloc] initWithFrame:NSZeroRect];
    document.identifier = @"settings-document";
    document.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = document;

    NSTextField *heading = BawanSetupLabel(@"Shortcuts", 22, NSFontWeightSemibold, BawanColor(BawanText));
    heading.font = BawanLabelFont(22);
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
    NSMutableArray<NSView *> *cards = [NSMutableArray array];
    for (NSUInteger i = 0; i < 2; ++i) {
        bawan::ShortcutAction action = static_cast<bawan::ShortcutAction>(i);
        NSTextField *name = BawanSetupLabel(i == 0 ? @"Translate selection" : @"Open translator",
            18, NSFontWeightSemibold, BawanColor(BawanText));
        name.font = BawanLabelFont(18);
        name.identifier = RowID(i, @"name");
        NSButton *enabled = [NSButton checkboxWithTitle:@"Use shortcut" target:self action:@selector(toggleEnabled:)];
        enabled.font = [NSFont systemFontOfSize:14];
        enabled.translatesAutoresizingMaskIntoConstraints = NO;
        enabled.tag = i;
        enabled.identifier = RowID(i, @"enabled");
        [enabled setAccessibilityLabel:[@"Use shortcut for " stringByAppendingString:ShortcutActionTitle(action)]];
        NSButton *record = [[BawanShortcutButton alloc] initWithFrame:NSZeroRect];
        record.target = self;
        record.action = @selector(beginRecording:);
        [record setButtonType:NSButtonTypeMomentaryPushIn];
        record.title = @"";
        record.bordered = NO;
        record.focusRingType = NSFocusRingTypeExterior;
        record.font = [NSFont systemFontOfSize:BawanInputFontSize weight:NSFontWeightMedium];
        record.contentTintColor = BawanColor(BawanText);
        record.translatesAutoresizingMaskIntoConstraints = NO;
        record.tag = i;
        record.identifier = RowID(i, @"key");
        record.toolTip = @"Click, then press a new key combination once. Set Once or Twice separately. Esc cancels.";
        [record.widthAnchor constraintEqualToConstant:128].active = YES;
        [record.heightAnchor constraintEqualToConstant:BawanInputHeight].active = YES;
        [record setAccessibilityLabel:[ShortcutActionTitle(action) stringByAppendingString:@" shortcut key"]];
        NSPopUpButton *count = [[BawanShortcutPressCount alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [count addItemsWithTitles:@[@"Once", @"Twice"]];
        count.bordered = NO;
        count.focusRingType = NSFocusRingTypeExterior;
        count.font = [NSFont systemFontOfSize:BawanInputFontSize weight:NSFontWeightMedium];
        count.contentTintColor = BawanColor(BawanText);
        count.translatesAutoresizingMaskIntoConstraints = NO;
        count.target = self;
        count.action = @selector(changePressCount:);
        count.tag = i;
        count.identifier = RowID(i, @"count");
        count.toolTip = @"For Twice, release the key between presses and press again within 400 ms.";
        [count.widthAnchor constraintEqualToConstant:80].active = YES;
        [count.heightAnchor constraintEqualToConstant:BawanInputHeight].active = YES;
        [count setAccessibilityLabel:[ShortcutActionTitle(action) stringByAppendingString:@" press count"]];
        NSButton *restore = [NSButton buttonWithImage:BawanSymbol(@"arrow.counterclockwise", nil, 15)
            target:self action:@selector(restoreShortcut:)];
        restore.translatesAutoresizingMaskIntoConstraints = NO;
        restore.tag = i;
        restore.identifier = RowID(i, @"reset");
        restore.bordered = NO;
        restore.contentTintColor = BawanAccentColor();
        restore.toolTip = @"Restore the default key, press count, and enabled state.";
        [restore.widthAnchor constraintEqualToConstant:24].active = YES;
        [restore.heightAnchor constraintEqualToConstant:28].active = YES;
        [restore setAccessibilityLabel:[@"Restore defaults for " stringByAppendingString:ShortcutActionTitle(action)]];
        NSStackView *controls = BawanSetupStack(@[record, count, restore], NSUserInterfaceLayoutOrientationHorizontal, 6);
        NSTextField *status = BawanSetupLabel(@"", 13, NSFontWeightRegular, BawanColor(BawanSecondaryText));
        status.identifier = RowID(i, @"status");
        [status setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
        BawanSetupActionButton *permission = [[BawanSetupActionButton alloc] initWithFrame:NSZeroRect];
        permission.title = @"Set up…";
        permission.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        permission.target = self;
        permission.action = @selector(requestPermission:);
        permission.tag = i;
        permission.identifier = RowID(i, @"permission");
        permission.translatesAutoresizingMaskIntoConstraints = NO;
        [permission.widthAnchor constraintEqualToConstant:76].active = YES;
        [permission.heightAnchor constraintEqualToConstant:28].active = YES;
        NSStackView *state = BawanSetupStack(@[status, [[NSView alloc] init], permission],
            NSUserInterfaceLayoutOrientationHorizontal, 8);
        NSStackView *cardContent = BawanSetupStack(@[name, enabled, controls, state],
            NSUserInterfaceLayoutOrientationVertical, 8);
        [name.widthAnchor constraintEqualToAnchor:cardContent.widthAnchor].active = YES;
        [state.widthAnchor constraintEqualToAnchor:cardContent.widthAnchor].active = YES;
        NSBox *card = Group(cardContent);
        card.identifier = RowID(i, @"card");
        [cards addObject:card];
        [_enabledButtons addObject:enabled];
        [_recordButtons addObject:record];
        [_pressCounts addObject:count];
        [_restoreButtons addObject:restore];
        [_statuses addObject:status];
        [_permissionButtons addObject:permission];
    }
    NSStackView *shortcutCards = BawanSetupStack(cards, NSUserInterfaceLayoutOrientationHorizontal, 16);
    shortcutCards.identifier = @"shortcut-group";
    shortcutCards.alignment = NSLayoutAttributeTop;
    shortcutCards.distribution = NSStackViewDistributionFillEqually;
    [cards[0].heightAnchor constraintEqualToAnchor:cards[1].heightAnchor].active = YES;
    _reservation = BawanSetupLabel(@"Custom shortcuts reserve their keys in other apps.",
        12, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    _reservation.identifier = @"shortcut-reservation";
    _reservation.hidden = YES;
    _shortcutHint = BawanSetupLabel(@"", 12, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    _shortcutHint.identifier = @"shortcut-feedback";
    _shortcutHint.hidden = YES;

    _loginSwitch = [[NSSwitch alloc] init];
    _loginSwitch.target = self;
    _loginSwitch.action = @selector(changeLogin:);
    _loginSwitch.identifier = @"launch-at-login";
    [_loginSwitch setAccessibilityLabel:@"Launch Bawan at login"];
    NSTextField *loginTitle = BawanSetupLabel(@"Launch at login", 15, NSFontWeightSemibold, BawanColor(BawanText));
    NSStackView *loginRow = BawanSetupStack(@[loginTitle, [[NSView alloc] init], _loginSwitch],
        NSUserInterfaceLayoutOrientationHorizontal, 10);
    _loginSettings = BawanSetupLink(@"Login Items…", self, @selector(openLoginSettings:));
    _loginSettings.identifier = @"login-items";
    _loginSettings.hidden = YES;
    [_loginSettings setAccessibilityLabel:@"Open Login Items settings"];
    _loginHint = BawanSetupLabel(@"", 13, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    _loginHint.identifier = @"login-hint";
    _loginHint.hidden = YES;
    NSStackView *loginContent = BawanSetupStack(@[loginRow, _loginSettings, _loginHint],
        NSUserInterfaceLayoutOrientationVertical, 6);
    loginContent.identifier = @"login-group";
    [loginRow.widthAnchor constraintEqualToAnchor:loginContent.widthAnchor].active = YES;
    [_loginHint.widthAnchor constraintEqualToAnchor:loginContent.widthAnchor].active = YES;

    _modelCheck = [[NSImageView alloc] init];
    _modelCheck.image = BawanSymbol(@"checkmark.circle.fill", nil, 18);
    _modelCheck.contentTintColor = BawanColor(BawanGold);
    _modelCheck.translatesAutoresizingMaskIntoConstraints = NO;
    [_modelCheck.widthAnchor constraintEqualToConstant:20].active = YES;
    [_modelCheck.heightAnchor constraintEqualToConstant:20].active = YES;
    [_modelCheck setAccessibilityElement:NO];
    NSTextField *modelTitle = BawanSetupLabel(@"Translation model", 15, NSFontWeightSemibold, BawanColor(BawanText));
    _modelStatus = BawanSetupLabel(@"Not prepared", 14, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    _modelStatus.identifier = @"settings-model-status";
    NSButton *modelLicense = BawanSetupLink(@"Model license", self, @selector(openModelLicense:));
    modelLicense.identifier = @"settings-model-license";
    _modelSetup = BawanSetupLink(@"Set up…", self, @selector(prepareModel:));
    _modelSetup.identifier = @"settings-model-setup";
    NSStackView *modelRow = BawanSetupStack(@[modelTitle, _modelCheck,
        _modelStatus, modelLicense, _modelSetup, [[NSView alloc] init]], NSUserInterfaceLayoutOrientationHorizontal, 10);
    _modelHint = BawanSetupLabel(@"", 13, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    _modelHint.identifier = @"settings-model-message";
    _modelHint.hidden = YES;
    _modelProgress = [[NSProgressIndicator alloc] init];
    _modelProgress.style = NSProgressIndicatorStyleBar;
    _modelProgress.indeterminate = NO;
    _modelProgress.minValue = 0;
    _modelProgress.maxValue = 1;
    _modelProgress.hidden = YES;
    _modelProgress.translatesAutoresizingMaskIntoConstraints = NO;
    _modelProgress.identifier = @"settings-model-progress";
    NSStackView *modelContent = BawanSetupStack(@[modelRow, _modelHint, _modelProgress],
        NSUserInterfaceLayoutOrientationVertical, 6);
    modelContent.identifier = @"settings-model-group";
    for (NSView *view in @[modelRow, _modelHint, _modelProgress]) {
        [view.widthAnchor constraintEqualToAnchor:modelContent.widthAnchor].active = YES;
    }
    NSImageView *privacyIcon = [[NSImageView alloc] init];
    privacyIcon.image = BawanSymbol(@"lock.shield", nil, 16);
    privacyIcon.contentTintColor = BawanColor(BawanSecondaryText);
    privacyIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [privacyIcon.widthAnchor constraintEqualToConstant:20].active = YES;
    [privacyIcon.heightAnchor constraintEqualToConstant:20].active = YES;
    [privacyIcon setAccessibilityElement:NO];
    NSTextField *privacy = BawanSetupLabel(@"Shortcut permissions do not affect typing or pasting.",
        14, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    privacy.identifier = @"local-processing";
    NSStackView *footer = BawanSetupStack(@[privacyIcon, privacy], NSUserInterfaceLayoutOrientationHorizontal, 8);
    NSStackView *content = BawanSetupStack(@[headingRow, shortcutCards, _reservation, _shortcutHint,
        BawanSetupRule(), loginContent, BawanSetupRule(), modelContent, BawanSetupRule(), footer],
        NSUserInterfaceLayoutOrientationVertical, 14);
    [document addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [masthead.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [masthead.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [masthead.topAnchor constraintEqualToAnchor:root.topAnchor],
        [masthead.heightAnchor constraintEqualToConstant:52],
        [_mascot.centerXAnchor constraintEqualToAnchor:masthead.centerXAnchor],
        [_mascot.centerYAnchor constraintEqualToAnchor:masthead.centerYAnchor],
        [_mascot.widthAnchor constraintEqualToConstant:40],
        [_mascot.heightAnchor constraintEqualToConstant:40],
        [subtitle.leadingAnchor constraintEqualToAnchor:masthead.leadingAnchor constant:88],
        [subtitle.trailingAnchor constraintLessThanOrEqualToAnchor:_mascot.leadingAnchor constant:-18],
        [subtitle.centerYAnchor constraintEqualToAnchor:masthead.centerYAnchor],
        [_back.trailingAnchor constraintEqualToAnchor:masthead.trailingAnchor constant:-24],
        [_back.centerYAnchor constraintEqualToAnchor:masthead.centerYAnchor],
        [_back.widthAnchor constraintEqualToConstant:140],
        [_back.heightAnchor constraintEqualToConstant:30],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:masthead.bottomAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
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
    _monitor.settingsActive = active;
    if (active) {
        [_monitor refresh];
        [self refresh];
    } else {
        [_mascot resetHoverAnimation];
        [self finishRecording];
    }
}

- (void)focusInitialControl {
    NSWindow *window = self.view.window;
    [window recalculateKeyViewLoop];
    [window makeFirstResponder:_back];
}

- (void)refresh {
    BOOL recording = _eventMonitor != nil;
    BOOL reservesCustomKeys = NO;
    const auto defaults = bawan::defaultShortcuts();
    for (NSUInteger i = 0; i < 2; ++i) {
        bawan::ShortcutAction action = static_cast<bawan::ShortcutAction>(i);
        bawan::ShortcutBinding binding = [_preferences bindingForAction:action];
        BOOL recordingRow = recording && _recordingAction == static_cast<NSInteger>(i);
        _enabledButtons[i].state = binding.enabled ? NSControlStateValueOn : NSControlStateValueOff;
        _enabledButtons[i].enabled = !recording;
        _recordButtons[i].title = recordingRow && !_finishingRecording ? @"Press keys…" : ShortcutKeyLabel(binding);
        _recordButtons[i].enabled = !_finishingRecording && (!recording || recordingRow);
        [_pressCounts[i] selectItemAtIndex:binding.pressCount - 1];
        _pressCounts[i].enabled = !recording;
        _restoreButtons[i].enabled = !recording;
        ShortcutAvailability availability = [_monitor availabilityForAction:action];
        BOOL custom = binding.keyCode != defaults[i].keyCode || binding.modifiers != defaults[i].modifiers ||
                      binding.pressCount != defaults[i].pressCount;
        reservesCustomKeys |= binding.enabled && custom &&
            (action != bawan::ShortcutAction::TranslateSelection || !bawan::isPassiveCopy(binding));
        BawanShortcutPresentation presentation = BawanPresentShortcut(availability);
        NSString *status = presentation.status;
        BawanColorRole statusRole = presentation.color;
        if (recording) {
            status = recordingRow ? (_finishingRecording ? @"Waiting for key release…" : @"Recording shortcut…") :
                (binding.enabled ? @"Paused while recording" : @"Off");
            statusRole = BawanSecondaryText;
        }
        _statuses[i].stringValue = status;
        _statuses[i].textColor = BawanColor(statusRole);
        _permissionButtons[i].title = availability == ShortcutAvailabilityFailed ? @"Retry" : @"Set up…";
        [_permissionButtons[i] setAccessibilityLabel:[presentation.actionTitle stringByAppendingFormat:@" for %@", ShortcutActionTitle(action)]];
        _permissionButtons[i].hidden = !presentation.needsAction;
        _permissionButtons[i].enabled = !recording;
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

- (void)setModelPhase:(BawanModelSetupPhase)phase message:(NSString *)message progress:(double)progress {
    _modelCheck.hidden = phase != BawanModelSetupReady;
    _modelSetup.hidden = phase == BawanModelSetupReady || phase == BawanModelSetupPreparing;
    _modelSetup.title = phase == BawanModelSetupFailed ? @"Retry" : @"Set up…";
    _modelProgress.hidden = phase != BawanModelSetupPreparing;
    _modelProgress.indeterminate = !std::isfinite(progress) || progress < 0;
    _modelProgress.doubleValue = std::isfinite(progress) ? std::clamp(progress, 0.0, 1.0) : 0;
    [self updateModelProgressAnimation];
    _modelHint.stringValue = message;
    _modelHint.hidden = message.length == 0 || phase == BawanModelSetupReady;
    _modelHint.textColor = BawanColor(phase == BawanModelSetupFailed ? BawanError : BawanSecondaryText);
    switch (phase) {
        case BawanModelSetupNeedsDownload: _modelStatus.stringValue = @"Not prepared"; break;
        case BawanModelSetupPreparing: _modelStatus.stringValue = @"Preparing…"; break;
        case BawanModelSetupReady: _modelStatus.stringValue = @"Ready"; break;
        case BawanModelSetupFailed: _modelStatus.stringValue = @"Needs attention"; break;
    }
    _modelStatus.textColor = BawanColor(phase == BawanModelSetupFailed ? BawanError : BawanSecondaryText);
    [self updateDocumentLayout];
    if (phase == BawanModelSetupFailed && message.length) [self revealMessage:_modelHint];
}

- (void)updateModelProgressAnimation {
    if (_active && !_modelProgress.hidden && _modelProgress.indeterminate) [_modelProgress startAnimation:nil];
    else [_modelProgress stopAnimation:nil];
}

- (void)openModelLicense:(id)sender { if (self.onModelLicense) self.onModelLicense(); }
- (void)prepareModel:(id)sender { if (self.onModelSetup) self.onModelSetup(); }

- (void)openLoginSettings:(id)sender { if (self.onLoginSettings) self.onLoginSettings(); }
- (void)changeLogin:(NSSwitch *)sender {
    if (self.onLoginChanged) self.onLoginChanged(sender.state == NSControlStateValueOn);
}

- (void)dealloc {
    [_modelProgress stopAnimation:nil];
    [_releaseTimer invalidate];
    if (_eventMonitor) {
        [NSEvent removeMonitor:_eventMonitor];
        _monitor.suspended = NO;
    }
    _monitor.settingsActive = NO;
}
@end
