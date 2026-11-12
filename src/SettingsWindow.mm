#import "SettingsWindow.h"
#import "LoreAppearance.h"

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

namespace {
NSTextField *Label(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
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
    NSBox *box = [[NSBox alloc] init];
    box.boxType = NSBoxCustom;
    box.titlePosition = NSNoTitle;
    box.borderWidth = 1;
    box.borderColor = NSColor.separatorColor;
    box.fillColor = NSColor.controlBackgroundColor;
    box.cornerRadius = 12;
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
} // namespace

@interface SettingsWindow () {
    NSTextField *_shortcutStatus;
    NSTextField *_shortcutHint;
    NSTextField *_loginHint;
    NSSwitch *_loginSwitch;
}
@end

@implementation SettingsWindow
- (instancetype)init {
    NSWindow *window = [[LoreSettingsWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 420)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    self = [super initWithWindow:window];
    if (!self) return nil;
    window.title = @"Lore Settings";
    window.releasedWhenClosed = NO;
    window.tabbingMode = NSWindowTabbingModeDisallowed;
    window.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace |
                                NSWindowCollectionBehaviorFullScreenAuxiliary;
    NSView *root = window.contentView;
    root.identifier = @"lore-settings";

    NSTextField *title = Label(@"Settings", 24, NSFontWeightSemibold, NSColor.labelColor);
    NSTextField *subtitle = Label(@"Shortcuts and startup", 13, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSStackView *header = Stack(@[title, subtitle], NSUserInterfaceLayoutOrientationVertical, 5);

    NSStackView *shortcutTitle = Stack(@[Icon(@"keyboard"),
        Label(@"Selection translation", 14, NSFontWeightSemibold, NSColor.labelColor)],
        NSUserInterfaceLayoutOrientationHorizontal, 10);
    NSTextField *shortcutDescription = Label(@"Select text in any app, then press ⌘C twice.",
        13, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _shortcutStatus = Label(@"Input Monitoring required", 12, NSFontWeightMedium, NSColor.secondaryLabelColor);
    _shortcutStatus.identifier = @"shortcut-status";
    NSButton *permissions = [NSButton buttonWithTitle:@"Input Monitoring…" target:self action:@selector(openInputMonitoring:)];
    permissions.identifier = @"input-monitoring";
    permissions.controlSize = NSControlSizeRegular;
    permissions.toolTip = @"Open Privacy & Security → Input Monitoring in System Settings";
    [permissions setAccessibilityLabel:@"Open Input Monitoring settings"];
    NSView *shortcutSpacer = [[NSView alloc] init];
    NSStackView *permissionRow = Stack(@[_shortcutStatus, shortcutSpacer, permissions],
        NSUserInterfaceLayoutOrientationHorizontal, 12);
    [_shortcutStatus setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];
    _shortcutHint = Label(@"Allow Lore in Input Monitoring. Typing and pasting always work.",
        12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSStackView *shortcutContent = Stack(@[shortcutTitle, shortcutDescription, permissionRow, _shortcutHint],
        NSUserInterfaceLayoutOrientationVertical, 12);
    NSBox *shortcutGroup = Group(shortcutContent);
    shortcutGroup.identifier = @"shortcut-group";
    for (NSView *view in @[shortcutDescription, permissionRow, _shortcutHint]) {
        [view.widthAnchor constraintEqualToAnchor:shortcutContent.widthAnchor].active = YES;
    }

    _loginSwitch = [[NSSwitch alloc] init];
    _loginSwitch.target = self;
    _loginSwitch.action = @selector(changeLogin:);
    _loginSwitch.identifier = @"launch-at-login";
    [_loginSwitch setAccessibilityLabel:@"Launch Lore at login"];
    NSView *loginSpacer = [[NSView alloc] init];
    NSStackView *loginTitle = Stack(@[Icon(@"power"),
        Label(@"Launch at login", 14, NSFontWeightSemibold, NSColor.labelColor), loginSpacer, _loginSwitch],
        NSUserInterfaceLayoutOrientationHorizontal, 10);
    NSTextField *loginDescription = Label(@"Open Lore automatically when you sign in.",
        13, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSButton *loginSettings = [NSButton buttonWithTitle:@"Login Items…" target:self action:@selector(openLoginSettings:)];
    loginSettings.identifier = @"login-items";
    loginSettings.bordered = NO;
    loginSettings.font = [NSFont systemFontOfSize:12];
    loginSettings.contentTintColor = LoreAccentColor();
    loginSettings.alignment = NSTextAlignmentLeft;
    [loginSettings setAccessibilityLabel:@"Open Login Items settings"];
    _loginHint = Label(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
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
    privacyIcon.contentTintColor = NSColor.secondaryLabelColor;
    NSTextField *privacy = Label(@"Translation runs locally on your Mac.",
        12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    privacy.identifier = @"local-processing";
    NSStackView *footer = Stack(@[privacyIcon, privacy], NSUserInterfaceLayoutOrientationHorizontal, 8);
    NSStackView *content = Stack(@[header, shortcutGroup, loginGroup, footer],
        NSUserInterfaceLayoutOrientationVertical, 16);
    [content setCustomSpacing:24 afterView:header];
    [root addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:24],
        [content.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24],
        [content.topAnchor constraintEqualToAnchor:root.topAnchor constant:24],
        [content.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-24],
        [shortcutGroup.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [loginGroup.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [footer.widthAnchor constraintEqualToAnchor:content.widthAnchor]
    ]];
    [self resizeToFit];
    [window center];
    return self;
}

- (void)resizeToFit {
    NSView *root = self.window.contentView;
    [root layoutSubtreeIfNeeded];
    CGFloat height = root.fittingSize.height;
    NSRect frame = self.window.frame;
    CGFloat previousHeight = frame.size.height;
    frame.size.height = [self.window frameRectForContentRect:NSMakeRect(0, 0, 500, height)].size.height;
    frame.origin.y += previousHeight - frame.size.height;
    [self.window setFrame:frame display:YES];
}

- (void)setShortcutAvailable:(BOOL)available permissionGranted:(BOOL)granted {
    _shortcutStatus.stringValue = available ? @"Shortcut ready" :
        granted ? @"Shortcut not active" : @"Input Monitoring required";
    _shortcutStatus.textColor = available ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
    _shortcutHint.stringValue = granted ? @"You can also type or paste text directly into Lore." :
        @"Allow Lore in Input Monitoring. Typing and pasting always work.";
    [self resizeToFit];
}

- (void)setLoginStatus:(SMAppServiceStatus)status message:(NSString *)message error:(BOOL)error {
    _loginSwitch.state = status == SMAppServiceStatusEnabled || status == SMAppServiceStatusRequiresApproval ?
        NSControlStateValueOn : NSControlStateValueOff;
    NSString *hint = message ?: (status == SMAppServiceStatusRequiresApproval ?
        @"Allow Lore in System Settings → General → Login Items." : @"");
    _loginHint.stringValue = hint;
    _loginHint.textColor = error ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    _loginHint.hidden = hint.length == 0;
    [self resizeToFit];
}

- (void)openInputMonitoring:(id)sender { if (self.onInputMonitoring) self.onInputMonitoring(); }
- (void)openLoginSettings:(id)sender { if (self.onLoginSettings) self.onLoginSettings(); }
- (void)changeLogin:(NSSwitch *)sender {
    if (self.onLoginChanged) self.onLoginChanged(sender.state == NSControlStateValueOn);
}
@end
