#import "SettingsViewController.h"
#import "BawanAppearance.h"
#import "BawanMascotView.h"
#import <CoreGraphics/CoreGraphics.h>

#include <set>

@interface BawanSettingsPaper : NSView
@end

@interface BawanSettingsDocument : NSView
@end

@implementation BawanSettingsDocument
- (BOOL)isFlipped { return YES; }
@end

@implementation BawanSettingsPaper
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    [BawanColor(BawanBackground) setFill];
    NSRectFill(self.bounds);
    BawanDrawPaper(self.bounds);
}
@end

@interface BawanSettingsMasthead : BawanSettingsPaper
@end

@implementation BawanSettingsMasthead
- (void)drawRect:(NSRect)dirtyRect { BawanDrawHeader(self.bounds); }
@end

@interface BawanSettingsGroup : NSBox
@end

@implementation BawanSettingsGroup
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.borderColor = BawanColor(BawanBorder);
    self.fillColor = BawanColor(BawanSurface);
    self.needsDisplay = YES;
}
@end

// AppKit still owns event tracking, key equivalents, menus and focus. Only the
// input face is shared with Bawan's other controls.
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
NSTextField *Label(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = weight >= NSFontWeightMedium ? BawanLabelFont(size) : BawanBodyFont(size);
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
    icon.image = BawanSymbol(name, nil, 17);
    icon.contentTintColor = BawanAccentColor();
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:22].active = YES;
    [icon.heightAnchor constraintEqualToConstant:22].active = YES;
    [icon setAccessibilityElement:NO];
    return icon;
}

NSBox *Group(NSView *content) {
    NSBox *box = [[BawanSettingsGroup alloc] init];
    box.boxType = NSBoxCustom;
    box.titlePosition = NSNoTitle;
    box.borderWidth = 1.5;
    box.borderColor = BawanColor(BawanBorder);
    box.fillColor = BawanColor(BawanSurface);
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

@interface SettingsViewController () {
    ShortcutPreferences *_preferences;
    ShortcutMonitor *_monitor;
    NSMutableArray<NSSwitch *> *_enabledSwitches;
    NSMutableArray<NSButton *> *_recordButtons;
    NSMutableArray<NSPopUpButton *> *_pressCounts;
    NSMutableArray<NSButton *> *_restoreButtons;
    NSMutableArray<NSTextField *> *_statuses;
    NSMutableArray<NSButton *> *_permissionButtons;
    NSTextField *_permissionHint;
    NSTextField *_reservation;
    NSTextField *_shortcutHint;
    NSTextField *_loginHint;
    NSSwitch *_loginSwitch;
    NSButton *_back;
    BawanMascotView *_mascot;
    id _eventMonitor;
    NSTimer *_releaseTimer;
    NSInteger _recordingAction;
    BOOL _finishingRecording;
    std::set<CGKeyCode> _heldKeys;
}
- (void)updateDocumentLayout;
- (void)setShortcutMessage:(NSString *)message error:(BOOL)error;
- (void)revealMessage:(NSTextField *)label;
- (NSEvent *)recordEvent:(NSEvent *)event;
- (void)finishRecording;
- (void)finishRecordingIfReleased;
- (BOOL)isRecordingKeyDown:(CGKeyCode)key;
@end

@implementation SettingsViewController

- (instancetype)initWithPreferences:(ShortcutPreferences *)preferences monitor:(ShortcutMonitor *)monitor {
    self = [super initWithNibName:nil bundle:nil];
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
    NSView *root = [[BawanSettingsPaper alloc] initWithFrame:NSMakeRect(0, 0, 720, 500)];
    self.view = root;
    root.identifier = @"bawan-settings";

    BawanSettingsMasthead *masthead = [[BawanSettingsMasthead alloc] init];
    masthead.identifier = @"settings-header";
    masthead.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:masthead];
    BawanMascotView *mascot = [[BawanMascotView alloc] init];
    _mascot = mascot;
    mascot.identifier = @"settings-mascot";
    mascot.translatesAutoresizingMaskIntoConstraints = NO;
    [mascot setAccessibilityElement:NO];
    [masthead addSubview:mascot];
    NSTextField *subtitle = Label(@"Settings", 12, NSFontWeightRegular,
                                  BawanColor(BawanHeaderText));
    subtitle.identifier = @"settings-subtitle";
    subtitle.alignment = NSTextAlignmentLeft;
    [masthead addSubview:subtitle];

    NSButton *back = [NSButton buttonWithTitle:@"Translator" target:self action:@selector(goBack:)];
    _back = back;
    back.identifier = @"settings-back";
    back.bordered = NO;
    back.font = BawanLabelFont(13);
    back.contentTintColor = BawanColor(BawanHeaderText);
    back.image = BawanSymbol(@"chevron.left", nil, 13);
    back.imagePosition = NSImageLeft;
    back.imageHugsTitle = YES;
    back.translatesAutoresizingMaskIntoConstraints = NO;
    back.toolTip = @"Back to translator (Esc)";
    [back setAccessibilityLabel:@"Back to translator"];
    [masthead addSubview:back];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.identifier = @"settings-scroll";
    scroll.borderType = NSNoBorder;
    BawanConfigurePaperScrollView(scroll);
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:scroll];
    NSView *document = [[BawanSettingsDocument alloc] initWithFrame:NSZeroRect];
    document.identifier = @"settings-document";
    document.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = document;

    NSView *shortcutTitle = [[NSView alloc] init];
    shortcutTitle.translatesAutoresizingMaskIntoConstraints = NO;
    NSImageView *keyboard = Icon(@"keyboard");
    NSTextField *shortcutName = Label(@"Global shortcuts", 14, NSFontWeightSemibold, BawanColor(BawanText));
    NSTextField *keyHeading = Label(@"Shortcut (click)", 12, NSFontWeightSemibold, BawanColor(BawanSecondaryText));
    keyHeading.identifier = @"shortcut-key-heading";
    NSTextField *pressesHeading = Label(@"Presses", 12, NSFontWeightSemibold, BawanColor(BawanSecondaryText));
    pressesHeading.identifier = @"shortcut-presses-heading";
    NSButton *help = [NSButton buttonWithImage:BawanSymbol(@"questionmark.circle", nil, 17)
        target:self action:@selector(showShortcutHelp:)];
    help.identifier = @"shortcut-help";
    help.bordered = NO;
    help.contentTintColor = BawanAccentColor();
    help.translatesAutoresizingMaskIntoConstraints = NO;
    help.toolTip = @"Shortcut help";
    [help setAccessibilityLabel:@"Shortcut help"];
    for (NSView *view in @[keyboard, shortcutName, keyHeading, pressesHeading, help]) {
        [shortcutTitle addSubview:view];
    }
    NSStackView *shortcutContent = Stack(@[shortcutTitle], NSUserInterfaceLayoutOrientationVertical, 6);
    [NSLayoutConstraint activateConstraints:@[
        [shortcutTitle.widthAnchor constraintEqualToAnchor:shortcutContent.widthAnchor],
        [shortcutTitle.heightAnchor constraintEqualToConstant:22],
        [keyboard.leadingAnchor constraintEqualToAnchor:shortcutTitle.leadingAnchor],
        [keyboard.centerYAnchor constraintEqualToAnchor:shortcutTitle.centerYAnchor],
        [shortcutName.leadingAnchor constraintEqualToAnchor:keyboard.trailingAnchor constant:10],
        [shortcutName.centerYAnchor constraintEqualToAnchor:shortcutTitle.centerYAnchor],
        [shortcutName.trailingAnchor constraintLessThanOrEqualToAnchor:keyHeading.leadingAnchor constant:-12],
        [keyHeading.centerYAnchor constraintEqualToAnchor:shortcutTitle.centerYAnchor],
        [pressesHeading.centerYAnchor constraintEqualToAnchor:shortcutTitle.centerYAnchor],
        [help.trailingAnchor constraintEqualToAnchor:shortcutTitle.trailingAnchor],
        [help.centerYAnchor constraintEqualToAnchor:shortcutTitle.centerYAnchor],
        [help.widthAnchor constraintEqualToConstant:28],
        [help.heightAnchor constraintEqualToConstant:22]
    ]];
    for (NSUInteger i = 0; i < 2; ++i) {
        bawan::ShortcutAction action = static_cast<bawan::ShortcutAction>(i);
        NSTextField *name = Label(ShortcutActionTitle(action), 13, NSFontWeightMedium, BawanColor(BawanText));
        name.maximumNumberOfLines = 1;
        [name.widthAnchor constraintEqualToConstant:152].active = YES;
        NSSwitch *enabled = [[NSSwitch alloc] init];
        enabled.target = self;
        enabled.action = @selector(toggleEnabled:);
        enabled.tag = i;
        enabled.identifier = RowID(i, @"enabled");
        [enabled setAccessibilityLabel:[@"Enable " stringByAppendingString:ShortcutActionTitle(action)]];
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
        count.font = BawanLabelFont(BawanInputFontSize);
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
        NSImage *restoreImage = BawanSymbol(@"arrow.counterclockwise", nil, 17);
        NSButton *restore = [NSButton buttonWithImage:restoreImage target:self action:@selector(restoreShortcut:)];
        restore.tag = i;
        restore.identifier = RowID(i, @"reset");
        restore.bordered = NO;
        restore.contentTintColor = BawanAccentColor();
        restore.toolTip = @"Restore the default key, press count, and enabled state.";
        [restore.widthAnchor constraintEqualToConstant:28].active = YES;
        [restore setAccessibilityLabel:[@"Restore defaults for " stringByAppendingString:ShortcutActionTitle(action)]];
        NSStackView *controls = Stack(@[name, enabled, record, count, restore], NSUserInterfaceLayoutOrientationHorizontal, 6);
        NSTextField *status = Label(@"", 12, NSFontWeightMedium, BawanColor(BawanSecondaryText));
        status.identifier = RowID(i, @"status");
        [status setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSButton *permission = [NSButton buttonWithTitle:@"" target:self action:@selector(requestPermission:)];
        permission.tag = i;
        permission.identifier = RowID(i, @"permission");
        permission.bordered = NO;
        permission.font = BawanLabelFont(12);
        permission.contentTintColor = BawanAccentColor();
        NSView *spacer = [[NSView alloc] init];
        NSStackView *state = Stack(@[status, spacer, permission], NSUserInterfaceLayoutOrientationHorizontal, 10);
        NSStackView *row = Stack(@[controls, state], NSUserInterfaceLayoutOrientationVertical, 4);
        [controls.widthAnchor constraintEqualToAnchor:row.widthAnchor].active = YES;
        [state.widthAnchor constraintEqualToAnchor:row.widthAnchor].active = YES;
        [shortcutContent addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:shortcutContent.widthAnchor].active = YES;
        if (i == 0) {
            [NSLayoutConstraint activateConstraints:@[
                [keyHeading.leadingAnchor constraintEqualToAnchor:record.leadingAnchor],
                [keyHeading.widthAnchor constraintEqualToAnchor:record.widthAnchor],
                [pressesHeading.leadingAnchor constraintEqualToAnchor:count.leadingAnchor],
                [pressesHeading.widthAnchor constraintEqualToAnchor:count.widthAnchor]
            ]];
        }
        [_enabledSwitches addObject:enabled];
        [_recordButtons addObject:record];
        [_pressCounts addObject:count];
        [_restoreButtons addObject:restore];
        [_statuses addObject:status];
        [_permissionButtons addObject:permission];
    }
    _permissionHint = Label(@"Allow Bawan in System Settings. Typing and pasting work without permissions.",
        12, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    _permissionHint.identifier = @"shortcut-permission-help";
    _permissionHint.hidden = YES;
    _reservation = Label(@"Custom shortcuts reserve their keys in other apps.",
        12, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    _reservation.identifier = @"shortcut-reservation";
    _reservation.hidden = YES;
    _shortcutHint = Label(@"", 12, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    _shortcutHint.identifier = @"shortcut-feedback";
    _shortcutHint.hidden = YES;
    for (NSTextField *label in @[_permissionHint, _reservation, _shortcutHint]) {
        [shortcutContent addArrangedSubview:label];
        [label.widthAnchor constraintEqualToAnchor:shortcutContent.widthAnchor].active = YES;
    }
    NSBox *shortcutGroup = Group(shortcutContent);
    shortcutGroup.identifier = @"shortcut-group";

    _loginSwitch = [[NSSwitch alloc] init];
    _loginSwitch.target = self;
    _loginSwitch.action = @selector(changeLogin:);
    _loginSwitch.identifier = @"launch-at-login";
    [_loginSwitch setAccessibilityLabel:@"Launch Bawan at login"];
    NSView *loginSpacer = [[NSView alloc] init];
    NSStackView *loginTitle = Stack(@[Icon(@"power"),
        Label(@"Launch at login", 14, NSFontWeightSemibold, BawanColor(BawanText)), loginSpacer, _loginSwitch],
        NSUserInterfaceLayoutOrientationHorizontal, 10);
    NSTextField *loginDescription = Label(@"Open Bawan automatically when you sign in.",
        13, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    NSButton *loginSettings = [NSButton buttonWithTitle:@"Login Items…" target:self action:@selector(openLoginSettings:)];
    loginSettings.identifier = @"login-items";
    loginSettings.bordered = NO;
    loginSettings.font = BawanLabelFont(12);
    loginSettings.contentTintColor = BawanAccentColor();
    loginSettings.alignment = NSTextAlignmentLeft;
    [loginSettings setAccessibilityLabel:@"Open Login Items settings"];
    _loginHint = Label(@"", 12, NSFontWeightRegular, BawanColor(BawanSecondaryText));
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
    privacyIcon.contentTintColor = BawanColor(BawanSecondaryText);
    NSTextField *privacy = Label(@"Translation runs locally on your Mac.",
        12, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    privacy.identifier = @"local-processing";
    NSStackView *footer = Stack(@[privacyIcon, privacy], NSUserInterfaceLayoutOrientationHorizontal, 8);
    NSStackView *content = Stack(@[shortcutGroup, loginGroup, footer],
        NSUserInterfaceLayoutOrientationVertical, 16);
    [document addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [masthead.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [masthead.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [masthead.topAnchor constraintEqualToAnchor:root.topAnchor],
        [masthead.heightAnchor constraintEqualToConstant:BawanHeaderHeight],
        [mascot.centerXAnchor constraintEqualToAnchor:masthead.centerXAnchor],
        [mascot.centerYAnchor constraintEqualToAnchor:masthead.centerYAnchor],
        [mascot.widthAnchor constraintEqualToConstant:BawanBrandMarkSize],
        [mascot.heightAnchor constraintEqualToConstant:BawanBrandMarkSize],
        [subtitle.leadingAnchor constraintEqualToAnchor:masthead.leadingAnchor constant:24],
        [subtitle.trailingAnchor constraintLessThanOrEqualToAnchor:mascot.leadingAnchor constant:-24],
        [subtitle.centerYAnchor constraintEqualToAnchor:masthead.centerYAnchor],
        [back.trailingAnchor constraintEqualToAnchor:masthead.trailingAnchor constant:-24],
        [back.centerYAnchor constraintEqualToAnchor:masthead.centerYAnchor],
        [back.widthAnchor constraintEqualToConstant:110],
        [back.heightAnchor constraintEqualToConstant:36],
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
        [content.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-24],
        [shortcutGroup.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [loginGroup.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [footer.widthAnchor constraintEqualToAnchor:content.widthAnchor]
    ]];
    // AppDelegate owns external preference/activation updates. Local actions
    // refresh directly; setActive: refreshes when this screen is shown again.
    [self refresh];
    return self;
}

- (void)updateDocumentLayout {
    [self.view layoutSubtreeIfNeeded];
}

- (void)setActive:(BOOL)active {
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
    BOOL needsPermission = NO;
    BOOL reservesCustomKeys = NO;
    const auto defaults = bawan::defaultShortcuts();
    for (NSUInteger i = 0; i < 2; ++i) {
        bawan::ShortcutAction action = static_cast<bawan::ShortcutAction>(i);
        bawan::ShortcutBinding binding = [_preferences bindingForAction:action];
        BOOL recordingRow = recording && _recordingAction == static_cast<NSInteger>(i);
        _enabledSwitches[i].state = binding.enabled ? NSControlStateValueOn : NSControlStateValueOff;
        _enabledSwitches[i].enabled = !recording;
        _recordButtons[i].title = recordingRow && !_finishingRecording ? @"Press keys…" : ShortcutKeyLabel(binding);
        _recordButtons[i].enabled = !_finishingRecording && (!recording || recordingRow);
        [_pressCounts[i] selectItemAtIndex:binding.pressCount - 1];
        _pressCounts[i].enabled = !recording;
        _restoreButtons[i].enabled = !recording;
        ShortcutAvailability availability = [_monitor availabilityForAction:action];
        needsPermission |= availability == ShortcutAvailabilityNeedsInputMonitoring ||
                           availability == ShortcutAvailabilityNeedsAccessibility;
        BOOL custom = binding.keyCode != defaults[i].keyCode || binding.modifiers != defaults[i].modifiers ||
                      binding.pressCount != defaults[i].pressCount;
        reservesCustomKeys |= binding.enabled && custom &&
            (action != bawan::ShortcutAction::TranslateSelection || !bawan::isPassiveCopy(binding));
        NSString *status = @"Off";
        NSString *permission = @"Retry";
        BawanColorRole statusRole = BawanSecondaryText;
        switch (availability) {
            case ShortcutAvailabilityOff: break;
            case ShortcutAvailabilityAvailable:
                status = @"Shortcut ready"; statusRole = BawanSuccess; break;
            case ShortcutAvailabilityNeedsInputMonitoring:
                status = @"Input Monitoring required"; permission = @"Open Input Monitoring…"; statusRole = BawanWarning; break;
            case ShortcutAvailabilityNeedsAccessibility:
                status = @"Accessibility required"; permission = @"Open Accessibility…"; statusRole = BawanWarning; break;
            case ShortcutAvailabilityFailed:
                status = @"Could not start monitoring"; statusRole = BawanError; break;
        }
        if (recording) {
            status = recordingRow ? (_finishingRecording ? @"Waiting for key release…" : @"Recording shortcut…") :
                (binding.enabled ? @"Paused while recording" : @"Off");
            statusRole = BawanSecondaryText;
        }
        _statuses[i].stringValue = status;
        _statuses[i].textColor = BawanColor(statusRole);
        _permissionButtons[i].title = permission;
        [_permissionButtons[i] setAccessibilityLabel:[permission stringByAppendingFormat:@" for %@", ShortcutActionTitle(action)]];
        _permissionButtons[i].hidden = availability == ShortcutAvailabilityOff || availability == ShortcutAvailabilityAvailable;
        _permissionButtons[i].enabled = !recording;
    }
    _permissionHint.hidden = !needsPermission;
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

- (void)toggleEnabled:(NSSwitch *)sender {
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
    [self updateDocumentLayout];
    if (hint.length > 0 && (error || (changed && status == SMAppServiceStatusRequiresApproval))) {
        [self revealMessage:_loginHint];
    }
}

- (void)openLoginSettings:(id)sender { if (self.onLoginSettings) self.onLoginSettings(); }
- (void)changeLogin:(NSSwitch *)sender {
    if (self.onLoginChanged) self.onLoginChanged(sender.state == NSControlStateValueOn);
}

- (void)dealloc {
    [_releaseTimer invalidate];
    if (_eventMonitor) {
        [NSEvent removeMonitor:_eventMonitor];
        _monitor.suspended = NO;
    }
    _monitor.settingsActive = NO;
}
@end
