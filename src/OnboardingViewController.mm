#import "OnboardingViewController.h"
#import "BawanMascotView.h"
#import "SetupUI.h"
#import "BawanChrome.h"

#include <algorithm>
#include <cmath>

namespace {
NSString *ShortcutID(NSUInteger index, NSString *part) {
    return [NSString stringWithFormat:@"onboarding-shortcut-%@-%@", index == 0 ? @"selection" : @"panel", part];
}

NSTextField *Label(NSString *text, CGFloat size, NSFontWeight weight, BawanColorRole role) {
    return BawanLabel(text, size, weight, BawanColor(role));
}

NSTextField *Heading(NSString *text, CGFloat size) {
    return BawanLabelWithFont(text, BawanLabelFont(size), BawanColor(BawanText));
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

    BawanSurfaceView *root = BawanMakeWindowSurface(@"bawan-onboarding", NSMakeRect(0, 0, 720, 500));
    self.view = root;

    BawanChromeHeader header = BawanAddHeader(root, @"onboarding-header", @"onboarding-mascot");
    _mascot = header.mascot;
    BawanChromeFooter footer = BawanAddFooter(root, @"onboarding-footer");
    BawanActionButton *start = BawanAddFooterPrimary(footer.footer, @"onboarding-start", @"Start translating",
        self, @selector(goBack:));
    _start = start;
    start.keyEquivalent = @"\r";
    start.toolTip = @"Start translating (Return)";
    _modelLicense = BawanAddFooterSecondary(footer.footer, @"onboarding-model-license", @"Model License",
        self, @selector(openModelLicense:));
    _modelLicense.image = BawanSymbol(@"doc.text", @"", 13);
    _modelLicense.imagePosition = NSImageLeft;
    _modelLicense.imageHugsTitle = YES;
    BawanAddFooterHint(footer.footer, @"onboarding-later", @"You can add shortcuts later.", start, _modelLicense);

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

    _title = Heading(@"Prepare your translator", 24);
    _title.identifier = @"onboarding-title";
    _modelIcon = [[NSImageView alloc] init];
    _modelIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [_modelIcon setAccessibilityElement:NO];
    [NSLayoutConstraint activateConstraints:@[
        [_modelIcon.widthAnchor constraintEqualToConstant:20],
        [_modelIcon.heightAnchor constraintEqualToConstant:20]
    ]];
    NSTextField *modelName = Label(@"Translation model", 15, NSFontWeightSemibold, BawanText);
    modelName.identifier = @"onboarding-model-title";
    _modelStatus = Label(@"Not set up", 15, NSFontWeightRegular, BawanSecondaryText);
    _modelStatus.identifier = @"onboarding-model-status";
    NSStackView *model = BawanSetupStack(@[_modelIcon, modelName, _modelStatus],
        NSUserInterfaceLayoutOrientationHorizontal, 8);

    _modelMessage = Label(@"", 14, NSFontWeightRegular, BawanSecondaryText);
    _modelMessage.identifier = @"onboarding-model-message";
    _modelAction = [[NSView alloc] init];
    _modelAction.identifier = @"onboarding-model-action";
    _modelAction.translatesAutoresizingMaskIntoConstraints = NO;
    BawanActionButton *modelSetup = BawanAddActionButton(_modelAction, @"onboarding-model-setup",
        @"Review license & download", self, @selector(setUpModel:), YES);
    modelSetup.wantsLayer = YES;
    modelSetup.pressFeedback = YES;
    _modelSetup = modelSetup;
    [NSLayoutConstraint activateConstraints:@[
        [_modelAction.heightAnchor constraintEqualToConstant:BawanFooterButtonHeight],
        [modelSetup.leadingAnchor constraintEqualToAnchor:_modelAction.leadingAnchor],
        [modelSetup.topAnchor constraintEqualToAnchor:_modelAction.topAnchor],
        [modelSetup.widthAnchor constraintEqualToConstant:240],
        [modelSetup.heightAnchor constraintEqualToConstant:BawanFooterButtonHeight]
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

    NSTextField *optional = Heading(@"Optional shortcuts", 20);
    optional.identifier = @"onboarding-shortcuts-title";
    NSView *firstRow = [self shortcutRow:0];
    NSView *secondRow = [self shortcutRow:1];
    _error = Label(@"", 13, NSFontWeightRegular, BawanError);
    _error.identifier = @"onboarding-error";
    _error.hidden = YES;

    NSArray<NSView *> *sections = @[_title, model, _modelMessage, _modelAction, _progress, BawanSetupRule(),
        optional, firstRow, BawanSetupRule(), secondRow, _error];
    NSStackView *content = BawanSetupStack(sections, NSUserInterfaceLayoutOrientationVertical, 12);
    [content setCustomSpacing:20 afterView:_progress];
    [content setCustomSpacing:20 afterView:_modelAction];
    [document addSubview:content];
    for (NSView *view in sections) {
        [view.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;
    }
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:header.header.bottomAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:footer.divider.topAnchor],
        [document.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [document.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [content.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:BawanChromeInset],
        [content.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-BawanChromeInset],
        [content.topAnchor constraintEqualToAnchor:document.topAnchor constant:BawanChromeInset],
        [content.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-BawanChromeInset]
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
        15, NSFontWeightSemibold, BawanText);
    name.identifier = ShortcutID(index, @"title");
    NSTextField *status = Label(@"", 13, NSFontWeightRegular, BawanSecondaryText);
    status.identifier = ShortcutID(index, @"status");
    NSStackView *description = BawanSetupStack(@[name, status], NSUserInterfaceLayoutOrientationVertical, 3);
    [row addSubview:description];
    NSTextField *key = [[BawanSetupKeycap alloc] initWithFrame:NSZeroRect];
    key.translatesAutoresizingMaskIntoConstraints = NO;
    key.identifier = ShortcutID(index, @"key");
    NSTextField *presses = Label(@"twice", 13, NSFontWeightRegular, BawanSecondaryText);
    presses.identifier = ShortcutID(index, @"presses");
    BawanActionButton *setup = BawanAddActionButton(nil, ShortcutID(index, @"setup"), @"Set up…",
        self, @selector(setUpShortcut:), NO);
    setup.font = BawanLabelFont(13);
    setup.tag = index;
    NSStackView *controls = BawanSetupStack(@[key, presses, setup], NSUserInterfaceLayoutOrientationHorizontal, 10);
    [row addSubview:controls];
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:56],
        [description.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [description.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [description.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:4],
        [description.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor constant:-4],
        [description.trailingAnchor constraintLessThanOrEqualToAnchor:controls.leadingAnchor constant:-12],
        [controls.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [controls.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [key.widthAnchor constraintEqualToConstant:64],
        [key.heightAnchor constraintEqualToConstant:BawanInputHeight],
        [setup.widthAnchor constraintEqualToConstant:96],
        [setup.heightAnchor constraintEqualToConstant:32]
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
        BawanApplyShortcutAction(setup, presentation, ShortcutActionTitle(action));
    }
    [self.view layoutSubtreeIfNeeded];
}

- (void)setActive:(BOOL)active {
    _active = active;
    _monitor.configurationActive = active;
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
