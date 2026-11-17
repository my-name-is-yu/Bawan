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
    BawanActionButton *start = BawanAddFooterPrimary(footer.footer, @"onboarding-start", @"Start Translating  ⌘↵",
        self, @selector(goBack:));
    _start = start;
    start.toolTip = @"Start translating (⌘Return)";
    _modelLicense = BawanAddFooterSecondary(footer.footer, @"onboarding-model-license", BawanModelLicenseTitle,
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

    // Layout: the hero pairs the mascot with the title and a one-line model status;
    // setup and the indented shortcut list follow, separated by full-width rules.
    NSImageView *heroMascot = [[NSImageView alloc] init];
    heroMascot.identifier = @"onboarding-hero-mascot";
    heroMascot.image = BawanMascotImageAtSize(120);
    heroMascot.imageScaling = NSImageScaleProportionallyUpOrDown;
    heroMascot.translatesAutoresizingMaskIntoConstraints = NO;
    [heroMascot setAccessibilityElement:NO];
    [heroMascot.widthAnchor constraintEqualToConstant:120].active = YES;
    [heroMascot.heightAnchor constraintEqualToConstant:120].active = YES;
    _title = BawanSetupHeading(@"Prepare Your Translator", BawanSetupTitleSize);
    _title.identifier = @"onboarding-title";
    _modelIcon = [[NSImageView alloc] init];
    _modelIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [_modelIcon setAccessibilityElement:NO];
    [_modelIcon.widthAnchor constraintEqualToConstant:16].active = YES;
    [_modelIcon.heightAnchor constraintEqualToConstant:16].active = YES;
    NSTextField *modelName = Label(@"Translation Model", BawanSetupRowTitleSize, NSFontWeightSemibold, BawanText);
    modelName.identifier = @"onboarding-model-title";
    _modelStatus = Label(@"", BawanSetupCaptionSize, NSFontWeightRegular, BawanSecondaryText);
    _modelStatus.identifier = @"onboarding-model-status";
    NSStackView *model = BawanSetupStack(@[_modelIcon, modelName, _modelStatus],
        NSUserInterfaceLayoutOrientationHorizontal, 8);
    NSStackView *intro = BawanSetupStack(@[_title, model], NSUserInterfaceLayoutOrientationVertical, 10);
    [intro setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *hero = BawanSetupStack(@[heroMascot, intro], NSUserInterfaceLayoutOrientationHorizontal, 20);
    hero.identifier = @"onboarding-hero";

    _modelMessage = Label(@"", BawanSetupBodySize, NSFontWeightRegular, BawanSecondaryText);
    _modelMessage.identifier = @"onboarding-model-message";
    BawanActionButton *modelSetup = BawanSetupButton(@"onboarding-model-setup", @"", BawanSetupModelActionWidth,
        self, @selector(setUpModel:));
    modelSetup.primary = YES;
    _modelSetup = modelSetup;
    _progress = [[BawanProgressBar alloc] init];
    _progress.identifier = @"onboarding-model-progress";
    _progress.style = NSProgressIndicatorStyleBar;
    _progress.indeterminate = NO;
    _progress.minValue = 0;
    _progress.maxValue = 1;
    _progress.translatesAutoresizingMaskIntoConstraints = NO;
    [_progress setAccessibilityLabel:@"Model setup progress"];
    [_progress.heightAnchor constraintEqualToConstant:8].active = YES;

    NSTextField *optional = BawanSetupHeading(@"Optional Shortcuts", BawanSetupSectionSize);
    optional.identifier = @"onboarding-shortcuts-title";
    NSView *firstRow = [self shortcutRow:0];
    NSView *secondRow = [self shortcutRow:1];
    _error = Label(@"", BawanSetupCaptionSize, NSFontWeightRegular, BawanError);
    _error.identifier = @"onboarding-error";
    _error.hidden = YES;

    NSView *topRule = BawanSetupRule();
    NSView *middleRule = BawanSetupRule();
    NSView *bottomRule = BawanSetupRule();
    NSStackView *content = BawanSetupStack(@[hero, _modelMessage, modelSetup, _progress, topRule, optional,
        firstRow, middleRule, secondRow, bottomRule, _error], NSUserInterfaceLayoutOrientationVertical, 10);
    [content setCustomSpacing:16 afterView:hero];
    // Everything but the setup button spans the content width; the button keeps its own width.
    NSArray<NSView *> *sections = @[hero, _modelMessage, _progress, topRule, optional,
        firstRow, middleRule, secondRow, bottomRule, _error];
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
    auto action = static_cast<bawan::ShortcutAction>(index);
    NSTextField *name = Label(ShortcutActionTitle(action), BawanSetupRowTitleSize, NSFontWeightSemibold, BawanText);
    name.identifier = ShortcutID(index, @"title");
    NSTextField *status = Label(@"", BawanSetupCaptionSize, NSFontWeightRegular, BawanSecondaryText);
    status.identifier = ShortcutID(index, @"status");
    NSTextField *key = [[BawanSetupKeycap alloc] initWithFrame:NSZeroRect];
    key.translatesAutoresizingMaskIntoConstraints = NO;
    key.identifier = ShortcutID(index, @"key");
    NSTextField *presses = [[BawanSetupKeycap alloc] initWithFrame:NSZeroRect];
    presses.translatesAutoresizingMaskIntoConstraints = NO;
    presses.identifier = ShortcutID(index, @"presses");
    [NSLayoutConstraint activateConstraints:@[
        [key.widthAnchor constraintEqualToConstant:BawanSetupKeyWidth],
        [key.heightAnchor constraintEqualToConstant:BawanInputHeight],
        [presses.widthAnchor constraintEqualToConstant:BawanSetupCountWidth],
        [presses.heightAnchor constraintEqualToConstant:BawanInputHeight]
    ]];
    BawanActionButton *setup = BawanSetupButton(ShortcutID(index, @"setup"), @"Set Up…",
        BawanSetupActionWidth, self, @selector(setUpShortcut:));
    setup.tag = index;
    [_shortcutKeys addObject:key];
    [_shortcutPresses addObject:presses];
    [_shortcutStatuses addObject:status];
    [_shortcutSetup addObject:setup];
    return BawanSetupInsetRow(ShortcutID(index, @"row"), name, status, @[key, presses, setup], 16, 12);
}

- (void)setModelPhase:(BawanModelSetupPhase)phase message:(NSString *)message progress:(double)progress {
    BOOL changed = _modelPhase != phase;
    _modelPhase = phase;
    BOOL ready = phase == BawanModelSetupReady;
    BOOL preparing = phase == BawanModelSetupPreparing;
    BOOL failed = phase == BawanModelSetupFailed;
    const BawanModelPresentation presentation = BawanPresentModel(phase);
    _title.stringValue = ready ? @"You’re Ready to Start" : failed ? @"Let’s Finish Setting Up" : @"Prepare Your Translator";
    _modelStatus.stringValue = presentation.status;
    _modelStatus.textColor = BawanColor(presentation.statusColor);
    _modelIcon.image = BawanSymbol(presentation.symbol, nil, 15);
    _modelIcon.contentTintColor = BawanColor(presentation.symbolColor);
    _modelMessage.stringValue = phase == BawanModelSetupNeedsDownload ?
        @"Review the model license, then download the translation model (about 573 MB)." : message;
    _modelMessage.textColor = BawanColor(failed ? BawanError : BawanSecondaryText);
    _modelMessage.hidden = ready || _modelMessage.stringValue.length == 0;
    _modelSetup.title = presentation.actionTitle;
    _modelSetup.hidden = presentation.actionTitle.length == 0;
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
        _shortcutPresses[index].stringValue = ShortcutPressCountTitle(binding.pressCount);
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
- (void)performPrimaryAction { [self goBack:nil]; }
- (void)setUpModel:(id)sender { if (self.onModelSetup) self.onModelSetup(); }
- (void)openModelLicense:(id)sender { if (self.onModelLicense) self.onModelLicense(); }

@end
