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

// The first step is the required model; the second offers the global shortcuts
// while the model downloads. The step follows the model phase, so a failed
// download returns to the model step with Retry.
bool IsModelStep(BawanModelSetupPhase phase) {
    return phase == BawanModelSetupNeedsDownload || phase == BawanModelSetupFailed;
}

constexpr NSUInteger ShortcutCount = 2;
}

@interface OnboardingViewController () {
    ShortcutPreferences *_preferences;
    ShortcutMonitor *_monitor;
    BawanModelSetupPhase _modelPhase;
    BOOL _active;
    BawanMascotView *_mascot;
    BawanMascotView *_heroMascot;
    NSScrollView *_scroll;
    NSView *_modelStep;
    NSView *_shortcutStep;
    NSTextField *_title;
    NSTextField *_modelStatus;
    NSTextField *_modelMessage;
    NSImageView *_modelIcon;
    NSMutableArray<NSTextField *> *_shortcutKeys;
    NSMutableArray<NSTextField *> *_shortcutPresses;
    NSMutableArray<NSTextField *> *_shortcutStatuses;
    NSMutableArray<NSButton *> *_shortcutSetup;
    NSTextField *_error;
    NSButton *_download;
    NSButton *_start;
    NSButton *_modelLicense;
    NSTextField *_footerNote;
    NSString *_progressMessage;
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

    // Both steps share the footer slots: the step's primary on the left, a note in
    // the middle, and Model License on the right during the model step.
    BawanChromeFooter footer = BawanAddFooter(root, @"onboarding-footer");
    _download = BawanAddFooterPrimary(footer.footer, @"onboarding-model-setup", @"",
        self, @selector(setUpModel:));
    _start = BawanAddFooterPrimary(footer.footer, @"onboarding-start", @"Set Up Later  ⌘↵",
        self, @selector(finish:));
    _modelLicense = BawanAddFooterSecondary(footer.footer, @"onboarding-model-license", BawanModelLicenseTitle,
        self, @selector(openModelLicense:));
    _modelLicense.image = BawanSymbol(@"doc.text", @"", 13);
    _modelLicense.imagePosition = NSImageLeft;
    _modelLicense.imageHugsTitle = YES;
    _footerNote = BawanAddFooterHint(footer.footer, @"onboarding-footer-note", @"", _download, _modelLicense);

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.identifier = @"onboarding-scroll";
    _scroll = scroll;
    scroll.borderType = NSNoBorder;
    BawanConfigurePaperScrollView(scroll);
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:scroll];
    BawanSetupDocument *document = [[BawanSetupDocument alloc] init];
    document.identifier = @"onboarding-document";
    document.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = document;

    _modelStep = [self buildModelStep];
    _shortcutStep = [self buildShortcutStep];
    NSStackView *content = BawanSetupStack(@[_modelStep, _shortcutStep], NSUserInterfaceLayoutOrientationVertical, 0);
    [document addSubview:content];
    for (NSView *step in @[_modelStep, _shortcutStep]) {
        [step.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;
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
    [self setModelPhase:BawanModelSetupNeedsDownload message:@"" progress:0];
    [self refresh];
    return self;
}

// The model step centers everything on the animated dog.
- (NSView *)buildModelStep {
    _heroMascot = [[BawanMascotView alloc] initPlainWithPointSize:120];
    _heroMascot.identifier = @"onboarding-hero-mascot";
    _heroMascot.translatesAutoresizingMaskIntoConstraints = NO;
    [_heroMascot setAccessibilityElement:NO];
    [_heroMascot.widthAnchor constraintEqualToConstant:120].active = YES;
    [_heroMascot.heightAnchor constraintEqualToConstant:120].active = YES;
    _title = BawanSetupHeading(@"Prepare Your Translator", BawanSetupTitleSize);
    _title.identifier = @"onboarding-title";
    _title.alignment = NSTextAlignmentCenter;
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
    _modelMessage = Label(@"", BawanSetupBodySize, NSFontWeightRegular, BawanSecondaryText);
    _modelMessage.identifier = @"onboarding-model-message";
    _modelMessage.alignment = NSTextAlignmentCenter;
    NSStackView *step = BawanSetupStack(@[_heroMascot, _title, model, _modelMessage],
        NSUserInterfaceLayoutOrientationVertical, 10);
    step.alignment = NSLayoutAttributeCenterX;
    [step setCustomSpacing:16 afterView:_heroMascot];
    [step setCustomSpacing:16 afterView:model];
    step.identifier = @"onboarding-step-model";
    for (NSView *text in @[_title, _modelMessage]) {
        [text.widthAnchor constraintLessThanOrEqualToAnchor:step.widthAnchor constant:-48].active = YES;
    }
    return step;
}

- (NSView *)buildShortcutStep {
    NSTextField *title = BawanSetupHeading(@"Translate Anywhere", BawanSetupTitleSize);
    title.identifier = @"onboarding-shortcut-title";
    NSTextField *detail = Label(@"Translate selected text from any app, or open Bawan from anywhere, with a quick double press.",
        BawanSetupBodySize, NSFontWeightRegular, BawanSecondaryText);
    NSStackView *hero = BawanSetupStack(@[title, detail], NSUserInterfaceLayoutOrientationVertical, 8);
    hero.identifier = @"onboarding-shortcut-intro";
    [title.widthAnchor constraintEqualToAnchor:hero.widthAnchor].active = YES;
    [detail.widthAnchor constraintEqualToAnchor:hero.widthAnchor].active = YES;
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObjects:hero, BawanSetupRule(), nil];
    for (NSUInteger index = 0; index < ShortcutCount; ++index) {
        [views addObject:[self shortcutRow:index]];
        [views addObject:BawanSetupRule()];
    }
    _error = Label(@"", BawanSetupCaptionSize, NSFontWeightRegular, BawanError);
    _error.identifier = @"onboarding-error";
    _error.hidden = YES;
    [views addObject:_error];
    NSStackView *step = BawanSetupStack(views, NSUserInterfaceLayoutOrientationVertical, 10);
    [step setCustomSpacing:16 afterView:hero];
    step.identifier = @"onboarding-step-shortcut";
    for (NSView *view in step.arrangedSubviews) [view.widthAnchor constraintEqualToAnchor:step.widthAnchor].active = YES;
    return step;
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
    BawanActionButton *setup = BawanSetupButton(ShortcutID(index, @"setup"), @"Set Up…", BawanSetupActionWidth,
        self, @selector(setUpShortcut:));
    setup.tag = index;
    [_shortcutKeys addObject:key];
    [_shortcutPresses addObject:presses];
    [_shortcutStatuses addObject:status];
    [_shortcutSetup addObject:setup];
    return BawanSetupInsetRow(ShortcutID(index, @"row"), name, status, @[key, presses, setup], 16, 12);
}

- (BOOL)showingModelStep { return !_modelStep.hidden; }

- (void)setModelPhase:(BawanModelSetupPhase)phase message:(NSString *)message progress:(double)progress {
    BOOL changed = _modelPhase != phase;
    BOOL wasModelStep = !_modelStep.hidden;
    _modelPhase = phase;
    BOOL failed = phase == BawanModelSetupFailed;
    BOOL modelStep = IsModelStep(phase);
    const BawanModelPresentation presentation = BawanPresentModel(phase);

    _modelStep.hidden = !modelStep;
    _shortcutStep.hidden = modelStep;
    _download.hidden = !modelStep;
    _modelLicense.hidden = !modelStep;
    _start.hidden = modelStep;

    _title.stringValue = failed ? @"Let’s Finish Setting Up" : @"Prepare Your Translator";
    _modelStatus.stringValue = presentation.status;
    _modelStatus.textColor = BawanColor(presentation.statusColor);
    _modelIcon.image = BawanSymbol(presentation.symbol, nil, 15);
    _modelIcon.contentTintColor = BawanColor(presentation.symbolColor);
    _modelMessage.stringValue = failed && message.length ? message :
        @"Bawan translates on your Mac with PLaMo 3 Translate. Review the model license, then download the model (about 573 MB).";
    _modelMessage.textColor = BawanColor(failed ? BawanError : BawanSecondaryText);
    if (modelStep) _download.title = [presentation.actionTitle stringByAppendingString:@"  ⌘↵"];

    if (phase == BawanModelSetupPreparing) {
        NSString *percent = std::isfinite(progress) && progress >= 0 ?
            [NSString stringWithFormat:@" %d%%", static_cast<int>(std::lround(std::clamp(progress, 0.0, 1.0) * 100))] : @"";
        _progressMessage = [@"Downloading the translation model…" stringByAppendingString:percent];
    } else if (phase == BawanModelSetupReady) {
        _progressMessage = @"Translation model ready.";
    } else {
        _progressMessage = nil;
    }
    [self updateFooterNote];
    [self.view layoutSubtreeIfNeeded];
    if (wasModelStep != modelStep && self.view.window.visible) BawanSetupPresentPage(self.view, _scroll);
    if (changed && failed && message.length && self.view.window.visible) {
        NSAccessibilityPostNotificationWithUserInfo(NSApp, NSAccessibilityAnnouncementRequestedNotification, @{
            NSAccessibilityAnnouncementKey: message,
            NSAccessibilityPriorityKey: @(NSAccessibilityPriorityMedium)
        });
    }
}

- (void)updateFooterNote {
    if ([self showingModelStep]) {
        _footerNote.stringValue = @"The model downloads directly from PFN to your Mac.";
    } else {
        _footerNote.stringValue = _progressMessage ?: @"";
    }
}

- (void)refresh {
    BOOL allReady = YES;
    for (NSUInteger index = 0; index < ShortcutCount; ++index) {
        auto action = static_cast<bawan::ShortcutAction>(index);
        auto binding = [_preferences bindingForAction:action];
        ShortcutAvailability availability = binding.enabled ? [_monitor availabilityForAction:action] :
            ShortcutAvailabilityOff;
        const auto presentation = BawanPresentShortcut(availability);
        _shortcutKeys[index].stringValue = ShortcutKeyLabel(binding);
        _shortcutPresses[index].stringValue = ShortcutPressCountTitle(binding.pressCount);
        _shortcutStatuses[index].stringValue = presentation.status;
        _shortcutStatuses[index].textColor = BawanColor(presentation.color);
        _shortcutSetup[index].hidden = availability == ShortcutAvailabilityAvailable;
        BawanApplyShortcutAction(_shortcutSetup[index], presentation, ShortcutActionTitle(action));
        allReady &= availability == ShortcutAvailabilityAvailable;
    }
    // "Later" while any shortcut still needs setup; afterwards the same button just starts.
    _start.title = allReady ? @"Start Translating  ⌘↵" : @"Set Up Later  ⌘↵";
    _start.toolTip = allReady ? @"Start translating (⌘Return)" :
        @"Continue now and finish the shortcuts later in Settings (⌘Return)";
    [self.view layoutSubtreeIfNeeded];
}

- (void)setActive:(BOOL)active {
    _active = active;
    _monitor.configurationActive = active;
    if (active) {
        [_monitor refresh];
        [self refresh];
    } else {
        [_mascot resetHoverAnimation];
        [_heroMascot resetHoverAnimation];
    }
}

- (void)focusInitialControl {
    BawanSetupPresentPage(self.view, _scroll);
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

- (void)finish:(id)sender { if (self.onFinish) self.onFinish(); }
- (void)performPrimaryAction {
    if ([self showingModelStep]) [self setUpModel:nil];
    else [self finish:nil];
}
- (void)setUpModel:(id)sender { if (self.onModelSetup) self.onModelSetup(); }
- (void)openModelLicense:(id)sender { if (self.onModelLicense) self.onModelLicense(); }

@end
