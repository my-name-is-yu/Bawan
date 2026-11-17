#import "OnboardingViewController.h"
#import "BawanMascotView.h"
#import "SetupUI.h"

#include <algorithm>
#include <cmath>

namespace {
NSString *ShortcutID(NSUInteger index, NSString *part) {
    return [NSString stringWithFormat:@"onboarding-shortcut-%@-%@", index == 0 ? @"selection" : @"panel", part];
}

NSTextField *Label(NSString *text, CGFloat size, NSFontWeight weight, BawanColorRole role) {
    return BawanSetupLabel(text, size, weight, BawanColor(role));
}

NSTextField *Heading(NSString *text, CGFloat size) {
    NSTextField *label = Label(text, size, NSFontWeightSemibold, BawanText);
    label.font = BawanLabelFont(size);
    return label;
}
}

@interface OnboardingViewController () {
    ShortcutPreferences *_preferences;
    ShortcutMonitor *_monitor;
    BawanModelSetupPhase _modelPhase;
    BOOL _active;
    BawanMascotView *_mascot;
    NSTextField *_title;
    NSTextField *_modelStatus;
    NSTextField *_modelMessage;
    NSImageView *_modelIcon;
    NSProgressIndicator *_progress;
    NSButton *_modelSetup;
    NSView *_modelAction;
    NSButton *_modelLicense;
    NSButton *_back;
    NSButton *_start;
    NSTextField *_error;
    NSMutableArray<NSTextField *> *_shortcutKeys;
    NSMutableArray<NSTextField *> *_shortcutPresses;
    NSMutableArray<NSTextField *> *_shortcutStatuses;
    NSMutableArray<NSButton *> *_shortcutSetup;
}
@end

@implementation OnboardingViewController

- (instancetype)initWithPreferences:(ShortcutPreferences *)preferences monitor:(ShortcutMonitor *)monitor {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _preferences = preferences;
    _monitor = monitor;
    _modelPhase = BawanModelSetupNeedsDownload;
    _shortcutKeys = [NSMutableArray array];
    _shortcutPresses = [NSMutableArray array];
    _shortcutStatuses = [NSMutableArray array];
    _shortcutSetup = [NSMutableArray array];

    BawanSetupPaper *root = [[BawanSetupPaper alloc] initWithFrame:NSMakeRect(0, 0, 720, 500)];
    root.identifier = @"bawan-onboarding";
    self.view = root;

    BawanSetupPaper *header = [[BawanSetupPaper alloc] init];
    header.identifier = @"onboarding-header";
    header.masthead = YES;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:header];
    NSTextField *brand = Label(@"Bawan", 13, NSFontWeightSemibold, BawanHeaderText);
    brand.identifier = @"onboarding-brand";
    [header addSubview:brand];
    _mascot = [[BawanMascotView alloc] init];
    _mascot.identifier = @"onboarding-mascot";
    _mascot.translatesAutoresizingMaskIntoConstraints = NO;
    [_mascot setAccessibilityElement:NO];
    [header addSubview:_mascot];
    _back = BawanSetupLink(@"Back to translator", self, @selector(goBack:));
    _back.identifier = @"onboarding-back";
    _back.image = BawanSymbol(@"chevron.left", nil, 12);
    _back.imagePosition = NSImageLeft;
    _back.contentTintColor = BawanColor(BawanHeaderText);
    _back.toolTip = @"Start translating (Esc)";
    [_back setAccessibilityLabel:@"Back to translator"];
    [header addSubview:_back];

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.identifier = @"onboarding-scroll";
    scroll.borderType = NSNoBorder;
    BawanConfigurePaperScrollView(scroll);
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:scroll];
    BawanSetupDocument *document = [[BawanSetupDocument alloc] init];
    document.identifier = @"onboarding-document";
    document.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = document;

    NSImageView *heroMascot = [[NSImageView alloc] init];
    heroMascot.identifier = @"onboarding-hero-mascot";
    heroMascot.image = BawanMascotImageAtSize(120);
    heroMascot.imageScaling = NSImageScaleProportionallyUpOrDown;
    heroMascot.translatesAutoresizingMaskIntoConstraints = NO;
    [heroMascot setAccessibilityElement:NO];
    [NSLayoutConstraint activateConstraints:@[
        [heroMascot.widthAnchor constraintEqualToConstant:120],
        [heroMascot.heightAnchor constraintEqualToConstant:120]
    ]];
    _title = Heading(@"Prepare your translator", 28);
    _title.identifier = @"onboarding-title";

    _modelIcon = [[NSImageView alloc] init];
    _modelIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [_modelIcon setAccessibilityElement:NO];
    [NSLayoutConstraint activateConstraints:@[
        [_modelIcon.widthAnchor constraintEqualToConstant:20],
        [_modelIcon.heightAnchor constraintEqualToConstant:20]
    ]];
    NSTextField *modelName = Label(@"Translation model", 14, NSFontWeightSemibold, BawanText);
    modelName.identifier = @"onboarding-model-title";
    _modelStatus = Label(@"Not set up", 14, NSFontWeightRegular, BawanSecondaryText);
    _modelStatus.identifier = @"onboarding-model-status";
    _modelLicense = BawanSetupLink(@"Model license", self, @selector(openModelLicense:));
    _modelLicense.identifier = @"onboarding-model-license";
    _modelLicense.font = [NSFont systemFontOfSize:14];
    BawanSetupActionButton *modelSetup = [[BawanSetupActionButton alloc] init];
    _modelSetup = modelSetup;
    modelSetup.primary = YES;
    modelSetup.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    modelSetup.target = self;
    modelSetup.action = @selector(setUpModel:);
    modelSetup.translatesAutoresizingMaskIntoConstraints = NO;
    _modelSetup.identifier = @"onboarding-model-setup";
    NSStackView *model = BawanSetupStack(@[_modelIcon, modelName, _modelStatus, _modelLicense],
        NSUserInterfaceLayoutOrientationHorizontal, 8);
    NSStackView *intro = BawanSetupStack(@[_title, model], NSUserInterfaceLayoutOrientationVertical, 10);
    NSStackView *hero = BawanSetupStack(@[heroMascot, intro], NSUserInterfaceLayoutOrientationHorizontal, 20);
    [intro setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    _modelMessage = Label(@"", 13,
        NSFontWeightRegular, BawanSecondaryText);
    _modelMessage.identifier = @"onboarding-model-message";
    _modelAction = [[NSView alloc] init];
    _modelAction.identifier = @"onboarding-model-action";
    _modelAction.translatesAutoresizingMaskIntoConstraints = NO;
    [_modelAction addSubview:modelSetup];
    [NSLayoutConstraint activateConstraints:@[
        [_modelAction.heightAnchor constraintEqualToConstant:40],
        [modelSetup.leadingAnchor constraintEqualToAnchor:_modelAction.leadingAnchor],
        [modelSetup.topAnchor constraintEqualToAnchor:_modelAction.topAnchor],
        [modelSetup.widthAnchor constraintEqualToConstant:252],
        [modelSetup.heightAnchor constraintEqualToConstant:40]
    ]];
    _progress = [[NSProgressIndicator alloc] init];
    _progress.identifier = @"onboarding-model-progress";
    _progress.style = NSProgressIndicatorStyleBar;
    _progress.indeterminate = NO;
    _progress.minValue = 0;
    _progress.maxValue = 1;
    _progress.translatesAutoresizingMaskIntoConstraints = NO;
    [_progress setAccessibilityLabel:@"Model setup progress"];
    [_progress.heightAnchor constraintEqualToConstant:6].active = YES;

    NSTextField *optional = Heading(@"Optional shortcuts", 22);
    optional.identifier = @"onboarding-shortcuts-title";
    NSView *firstRow = [self shortcutRow:0];
    NSView *secondRow = [self shortcutRow:1];
    NSView *topRule = BawanSetupRule();
    NSView *middleRule = BawanSetupRule();
    NSView *bottomRule = BawanSetupRule();

    _error = Label(@"", 13, NSFontWeightRegular, BawanError);
    _error.identifier = @"onboarding-error";
    _error.hidden = YES;
    NSTextField *later = Label(@"You can add shortcuts later.", 13, NSFontWeightRegular, BawanSecondaryText);
    later.identifier = @"onboarding-later";
    BawanSetupActionButton *start = [[BawanSetupActionButton alloc] init];
    _start = start;
    start.primary = YES;
    start.title = @"Start translating";
    start.font = BawanLabelFont(18);
    start.target = self;
    start.action = @selector(goBack:);
    start.identifier = @"onboarding-start";
    start.translatesAutoresizingMaskIntoConstraints = NO;
    start.keyEquivalent = @"\r";
    NSView *footer = [[NSView alloc] init];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:later];
    [footer addSubview:start];
    [NSLayoutConstraint activateConstraints:@[
        [footer.heightAnchor constraintEqualToConstant:44],
        [later.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor],
        [later.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [later.trailingAnchor constraintLessThanOrEqualToAnchor:start.leadingAnchor constant:-16],
        [start.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor],
        [start.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [start.widthAnchor constraintEqualToConstant:264],
        [start.heightAnchor constraintEqualToConstant:44]
    ]];
    NSStackView *content = BawanSetupStack(@[hero, _modelMessage, _modelAction, _progress, topRule, optional,
        firstRow, middleRule, secondRow, bottomRule, _error, footer],
        NSUserInterfaceLayoutOrientationVertical, 10);
    [document addSubview:content];
    for (NSView *view in @[hero, _modelMessage, _modelAction, _progress, topRule, optional, firstRow,
                           middleRule, secondRow, bottomRule, _error, footer]) {
        [view.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;
    }
    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [header.topAnchor constraintEqualToAnchor:root.topAnchor],
        [header.heightAnchor constraintEqualToConstant:52],
        [brand.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:88],
        [brand.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [_mascot.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [_mascot.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [_mascot.widthAnchor constraintEqualToConstant:40],
        [_mascot.heightAnchor constraintEqualToConstant:40],
        [_back.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [_back.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [_back.heightAnchor constraintEqualToConstant:28],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [document.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [document.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [content.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:24],
        [content.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-24],
        [content.topAnchor constraintEqualToAnchor:document.topAnchor constant:20],
        [content.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-20]
    ]];
    [self setModelPhase:BawanModelSetupNeedsDownload message:_modelMessage.stringValue progress:0];
    [self refresh];
    return self;
}

- (NSView *)shortcutRow:(NSUInteger)index {
    NSView *row = [[NSView alloc] init];
    row.identifier = ShortcutID(index, @"row");
    row.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *name = Label(index == 0 ? @"Translate selected text" : @"Open Bawan from anywhere",
        16, NSFontWeightSemibold, BawanText);
    name.identifier = ShortcutID(index, @"title");
    NSTextField *status = Label(@"", 14, NSFontWeightRegular, BawanSecondaryText);
    status.identifier = ShortcutID(index, @"status");
    NSStackView *description = BawanSetupStack(@[name, status], NSUserInterfaceLayoutOrientationVertical, 3);
    [row addSubview:description];
    NSTextField *key = [[BawanSetupKeycap alloc] initWithFrame:NSZeroRect];
    key.translatesAutoresizingMaskIntoConstraints = NO;
    key.identifier = ShortcutID(index, @"key");
    NSTextField *presses = Label(@"twice", 13, NSFontWeightRegular, BawanSecondaryText);
    presses.identifier = ShortcutID(index, @"presses");
    BawanSetupActionButton *setup = [[BawanSetupActionButton alloc] initWithFrame:NSZeroRect];
    setup.title = @"Set up…";
    setup.target = self;
    setup.action = @selector(setUpShortcut:);
    setup.translatesAutoresizingMaskIntoConstraints = NO;
    setup.identifier = ShortcutID(index, @"setup");
    setup.tag = index;
    NSStackView *controls = BawanSetupStack(@[key, presses, setup], NSUserInterfaceLayoutOrientationHorizontal, 10);
    [row addSubview:controls];
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:64],
        [description.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [description.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [description.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:5],
        [description.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor constant:-5],
        [description.trailingAnchor constraintLessThanOrEqualToAnchor:controls.leadingAnchor constant:-12],
        [controls.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12],
        [controls.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [key.widthAnchor constraintEqualToConstant:64],
        [key.heightAnchor constraintEqualToConstant:28],
        [setup.widthAnchor constraintEqualToConstant:94],
        [setup.heightAnchor constraintEqualToConstant:30]
    ]];
    [_shortcutKeys addObject:key];
    [_shortcutPresses addObject:presses];
    [_shortcutStatuses addObject:status];
    [_shortcutSetup addObject:setup];
    return row;
}

- (void)setModelPhase:(BawanModelSetupPhase)phase message:(NSString *)message progress:(double)progress {
    BOOL changed = _modelPhase != phase;
    _modelPhase = phase;
    BOOL ready = phase == BawanModelSetupReady;
    BOOL preparing = phase == BawanModelSetupPreparing;
    BOOL failed = phase == BawanModelSetupFailed;
    _title.stringValue = ready ? @"You’re ready to start" : failed ? @"Let’s finish setting up" : @"Prepare your translator";
    _modelStatus.stringValue = ready ? @"Ready" : preparing ? @"Preparing…" : failed ? @"Needs attention" : @"Not set up";
    _modelStatus.textColor = BawanColor(failed ? BawanError : ready ? BawanSuccess : BawanSecondaryText);
    _modelIcon.image = BawanSymbol(ready ? @"checkmark.circle.fill" : failed ? @"exclamationmark.circle" : @"arrow.down.circle", nil, 17);
    _modelIcon.contentTintColor = BawanColor(ready ? BawanGold : failed ? BawanError : BawanSecondaryText);
    _modelMessage.stringValue = phase == BawanModelSetupNeedsDownload ?
        @"Review the model license, then download the translation model (about 573 MB)." : message;
    _modelMessage.textColor = BawanColor(failed ? BawanError : BawanSecondaryText);
    _modelMessage.hidden = ready || _modelMessage.stringValue.length == 0;
    _modelSetup.title = failed ? @"Retry model setup" : @"Review license & download";
    _modelAction.hidden = ready || preparing;
    _modelSetup.hidden = ready || preparing;
    _modelSetup.enabled = !preparing;
    _progress.hidden = !preparing;
    _progress.indeterminate = !std::isfinite(progress) || progress < 0;
    _progress.doubleValue = std::isfinite(progress) ? std::clamp(progress, 0.0, 1.0) : 0;
    if (preparing && _active && _progress.indeterminate) [_progress startAnimation:nil];
    else [_progress stopAnimation:nil];
    _start.enabled = ready;
    _back.hidden = !ready;
    [self.view layoutSubtreeIfNeeded];
    if (changed && failed && message.length && self.view.window.visible) {
        NSAccessibilityPostNotificationWithUserInfo(NSApp, NSAccessibilityAnnouncementRequestedNotification, @{
            NSAccessibilityAnnouncementKey: message,
            NSAccessibilityPriorityKey: @(NSAccessibilityPriorityMedium)
        });
    }
}

- (void)refresh {
    for (NSUInteger index = 0; index < 2; ++index) {
        auto action = static_cast<bawan::ShortcutAction>(index);
        auto binding = [_preferences bindingForAction:action];
        ShortcutAvailability availability = binding.enabled ? [_monitor availabilityForAction:action] : ShortcutAvailabilityOff;
        const auto presentation = BawanPresentShortcut(availability);
        _shortcutKeys[index].stringValue = ShortcutKeyLabel(binding);
        _shortcutPresses[index].stringValue = binding.pressCount == 1 ? @"once" : @"twice";
        _shortcutStatuses[index].stringValue = presentation.status;
        _shortcutStatuses[index].textColor = BawanColor(presentation.color);
        NSButton *setup = _shortcutSetup[index];
        setup.hidden = availability == ShortcutAvailabilityAvailable;
        setup.title = availability == ShortcutAvailabilityOff ? @"Enable…" :
            availability == ShortcutAvailabilityFailed ? @"Retry" : @"Set up…";
        [setup setAccessibilityLabel:[setup.title stringByAppendingFormat:@" for %@", ShortcutActionTitle(action)]];
    }
    [self.view layoutSubtreeIfNeeded];
}

- (void)setActive:(BOOL)active {
    _active = active;
    _monitor.settingsActive = active;
    if (active) {
        [_monitor refresh];
        [self refresh];
        if (_modelPhase == BawanModelSetupPreparing && _progress.indeterminate) [_progress startAnimation:nil];
    } else {
        [_progress stopAnimation:nil];
        [_mascot resetHoverAnimation];
    }
}

- (void)focusInitialControl {
    [self.view.window recalculateKeyViewLoop];
    NSView *control = _start.enabled ? _start : !_modelSetup.hidden ? _modelSetup : _modelLicense;
    [self.view.window makeFirstResponder:control];
}

- (void)setUpShortcut:(NSButton *)sender {
    auto action = static_cast<bawan::ShortcutAction>(sender.tag);
    auto binding = [_preferences bindingForAction:action];
    NSString *error = nil;
    if (!binding.enabled) {
        binding.enabled = true;
        if (![_preferences setBinding:binding forAction:action error:&error]) {
            _error.stringValue = error ?: @"Unable to enable this shortcut.";
            _error.hidden = NO;
            [self.view layoutSubtreeIfNeeded];
            [_error scrollRectToVisible:_error.bounds];
            if (self.view.window.visible) {
                NSAccessibilityPostNotificationWithUserInfo(NSApp, NSAccessibilityAnnouncementRequestedNotification, @{
                    NSAccessibilityAnnouncementKey: _error.stringValue,
                    NSAccessibilityPriorityKey: @(NSAccessibilityPriorityMedium)
                });
            }
            return;
        }
    }
    _error.hidden = YES;
    _error.stringValue = @"";
    [_monitor requestPermissionForAction:action];
    [self refresh];
}

- (void)goBack:(id)sender {
    if (_modelPhase == BawanModelSetupReady && self.onBack) self.onBack();
}
- (void)setUpModel:(id)sender { if (self.onModelSetup) self.onModelSetup(); }
- (void)openModelLicense:(id)sender { if (self.onModelLicense) self.onModelLicense(); }

@end
