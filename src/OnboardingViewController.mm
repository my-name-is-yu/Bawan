#import "OnboardingViewController.h"
#import "BawanMascotView.h"
#import "SetupUI.h"
#import "BawanChrome.h"

#include <algorithm>
#include <cmath>

namespace {
NSString *ShortcutID(NSString *part) {
    return [@"onboarding-shortcut-selection-" stringByAppendingString:part];
}

NSTextField *Label(NSString *text, CGFloat size, NSFontWeight weight, BawanColorRole role) {
    return BawanLabel(text, size, weight, BawanColor(role));
}

// The first step is the required model; the second offers the selection shortcut
// while the model downloads. The step follows the model phase, so a failed
// download returns to the model step with Retry.
bool IsModelStep(BawanModelSetupPhase phase) {
    return phase == BawanModelSetupNeedsDownload || phase == BawanModelSetupFailed;
}

constexpr auto SelectionAction = bawan::ShortcutAction::TranslateSelection;
}

@interface OnboardingViewController () {
    ShortcutPreferences *_preferences;
    ShortcutMonitor *_monitor;
    BawanModelSetupPhase _modelPhase;
    BOOL _active;
    BawanMascotView *_mascot;
    NSScrollView *_scroll;
    NSView *_modelStep;
    NSView *_shortcutStep;
    NSTextField *_title;
    NSTextField *_modelStatus;
    NSTextField *_modelMessage;
    NSImageView *_modelIcon;
    NSTextField *_shortcutKey;
    NSTextField *_shortcutPresses;
    NSTextField *_shortcutStatus;
    NSButton *_shortcutSetup;
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

// The hero pairs the large mascot with a title and one supporting line.
- (NSStackView *)heroWithIdentifier:(NSString *)identifier title:(NSTextField *)title detail:(NSView *)detail {
    NSImageView *mascot = [[NSImageView alloc] init];
    mascot.identifier = [identifier stringByAppendingString:@"-mascot"];
    mascot.image = BawanMascotImageAtSize(120);
    mascot.imageScaling = NSImageScaleProportionallyUpOrDown;
    mascot.translatesAutoresizingMaskIntoConstraints = NO;
    [mascot setAccessibilityElement:NO];
    [mascot.widthAnchor constraintEqualToConstant:120].active = YES;
    [mascot.heightAnchor constraintEqualToConstant:120].active = YES;
    NSStackView *intro = BawanSetupStack(@[title, detail], NSUserInterfaceLayoutOrientationVertical, 10);
    [intro setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    [title.widthAnchor constraintEqualToAnchor:intro.widthAnchor].active = YES;
    NSStackView *hero = BawanSetupStack(@[mascot, intro], NSUserInterfaceLayoutOrientationHorizontal, 20);
    hero.identifier = identifier;
    return hero;
}

- (NSView *)buildModelStep {
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
    NSStackView *hero = [self heroWithIdentifier:@"onboarding-hero" title:_title detail:model];
    _modelMessage = Label(@"", BawanSetupBodySize, NSFontWeightRegular, BawanSecondaryText);
    _modelMessage.identifier = @"onboarding-model-message";
    NSStackView *step = BawanSetupStack(@[hero, _modelMessage], NSUserInterfaceLayoutOrientationVertical, 16);
    step.identifier = @"onboarding-step-model";
    for (NSView *view in step.arrangedSubviews) [view.widthAnchor constraintEqualToAnchor:step.widthAnchor].active = YES;
    return step;
}

- (NSView *)buildShortcutStep {
    NSTextField *title = BawanSetupHeading(@"Translate Anywhere", BawanSetupTitleSize);
    title.identifier = @"onboarding-shortcut-title";
    NSTextField *detail = Label(@"Select text in any app and press ⌘C twice. Bawan opens with the translation.",
        BawanSetupBodySize, NSFontWeightRegular, BawanSecondaryText);
    NSStackView *hero = [self heroWithIdentifier:@"onboarding-shortcut-hero" title:title detail:detail];
    [detail.widthAnchor constraintEqualToAnchor:title.widthAnchor].active = YES;

    NSTextField *name = Label(ShortcutActionTitle(SelectionAction), BawanSetupRowTitleSize, NSFontWeightSemibold, BawanText);
    name.identifier = ShortcutID(@"title");
    _shortcutStatus = Label(@"", BawanSetupCaptionSize, NSFontWeightRegular, BawanSecondaryText);
    _shortcutStatus.identifier = ShortcutID(@"status");
    _shortcutKey = [[BawanSetupKeycap alloc] initWithFrame:NSZeroRect];
    _shortcutKey.translatesAutoresizingMaskIntoConstraints = NO;
    _shortcutKey.identifier = ShortcutID(@"key");
    _shortcutPresses = [[BawanSetupKeycap alloc] initWithFrame:NSZeroRect];
    _shortcutPresses.translatesAutoresizingMaskIntoConstraints = NO;
    _shortcutPresses.identifier = ShortcutID(@"presses");
    [NSLayoutConstraint activateConstraints:@[
        [_shortcutKey.widthAnchor constraintEqualToConstant:BawanSetupKeyWidth],
        [_shortcutKey.heightAnchor constraintEqualToConstant:BawanInputHeight],
        [_shortcutPresses.widthAnchor constraintEqualToConstant:BawanSetupCountWidth],
        [_shortcutPresses.heightAnchor constraintEqualToConstant:BawanInputHeight]
    ]];
    _shortcutSetup = BawanSetupButton(ShortcutID(@"setup"), @"Set Up…", BawanSetupActionWidth,
        self, @selector(setUpShortcut:));
    NSView *row = BawanSetupInsetRow(ShortcutID(@"row"), name, _shortcutStatus,
        @[_shortcutKey, _shortcutPresses, _shortcutSetup], 16, 12);
    _error = Label(@"", BawanSetupCaptionSize, NSFontWeightRegular, BawanError);
    _error.identifier = @"onboarding-error";
    _error.hidden = YES;
    NSTextField *more = Label(@"Open Translator and other shortcuts are in Settings.",
        BawanSetupCaptionSize, NSFontWeightRegular, BawanSecondaryText);
    more.identifier = @"onboarding-shortcut-more";
    NSView *topRule = BawanSetupRule();
    NSView *bottomRule = BawanSetupRule();
    NSStackView *step = BawanSetupStack(@[hero, topRule, row, bottomRule, _error, more],
        NSUserInterfaceLayoutOrientationVertical, 10);
    [step setCustomSpacing:16 afterView:hero];
    step.identifier = @"onboarding-step-shortcut";
    for (NSView *view in step.arrangedSubviews) [view.widthAnchor constraintEqualToAnchor:step.widthAnchor].active = YES;
    return step;
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
    auto binding = [_preferences bindingForAction:SelectionAction];
    ShortcutAvailability availability = binding.enabled ? [_monitor availabilityForAction:SelectionAction] :
        ShortcutAvailabilityOff;
    const auto presentation = BawanPresentShortcut(availability);
    _shortcutKey.stringValue = ShortcutKeyLabel(binding);
    _shortcutPresses.stringValue = ShortcutPressCountTitle(binding.pressCount);
    _shortcutStatus.stringValue = presentation.status;
    _shortcutStatus.textColor = BawanColor(presentation.color);
    _shortcutSetup.hidden = availability == ShortcutAvailabilityAvailable;
    BawanApplyShortcutAction(_shortcutSetup, presentation, ShortcutActionTitle(SelectionAction));
    // "Later" only while the shortcut still needs setup; afterwards the same button just starts.
    _start.title = availability == ShortcutAvailabilityAvailable ? @"Start Translating  ⌘↵" : @"Set Up Later  ⌘↵";
    _start.toolTip = availability == ShortcutAvailabilityAvailable ? @"Start translating (⌘Return)" :
        @"Continue without the shortcut; set it up later in Settings (⌘Return)";
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
    }
}

- (void)focusInitialControl {
    BawanSetupPresentPage(self.view, _scroll);
}

- (void)setUpShortcut:(NSButton *)sender {
    auto binding = [_preferences bindingForAction:SelectionAction];
    NSString *error = nil;
    if (!binding.enabled) {
        binding.enabled = true;
        if (![_preferences setBinding:binding forAction:SelectionAction error:&error]) {
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
    [_monitor requestPermissionForAction:SelectionAction];
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
