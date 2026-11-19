#import "OnboardingViewController.h"
#import "BawanMascotView.h"
#import "SetupUI.h"
#import "BawanChrome.h"

#include <vector>

namespace {
enum class TrialPhase { Ready, Translating, Complete };

NSString *ShortcutID(bawan::ShortcutAction action, NSString *part) {
    return [NSString stringWithFormat:@"onboarding-shortcut-%@-%@", ShortcutSlug(action), part];
}

NSTextField *Label(NSString *text, CGFloat size, NSFontWeight weight, BawanColorRole role) {
    return BawanLabel(text, size, weight, BawanColor(role));
}

// The first step is the required model; the second offers the global shortcuts
// while the model downloads. The step follows the model phase, so a failed
// download returns to the model step with Retry.
bool IsModelStep(BawanModelSetupPhase phase) {
    return phase == BawanModelSetupNeedsDownload || phase == BawanModelSetupFailed ||
        phase == BawanModelSetupResumableFailure;
}

// The controls of one shortcut row, refreshed together from its binding.
struct ShortcutRow {
    bawan::ShortcutAction action;
    NSTextField *key;
    NSTextField *presses;
    NSTextField *status;
    BawanActionButton *setup;
};
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
    std::vector<ShortcutRow> _shortcutRows;
    NSView *_selectionTrial;
    NSTextView *_selectionSample;
    NSTextField *_trialInstructions;
    NSTextField *_trialStatus;
    bawan::ShortcutBinding _trialBinding;
    BOOL _selectionReady;
    TrialPhase _trialPhase;
    NSUInteger _trialAttempt;
    NSString *_trialOutput;
    bawan::Direction _trialDirection;
    NSTextField *_error;
    NSButton *_primary;
    NSButton *_modelLicense;
    NSButton *_modelControl;
    NSTextField *_footerNote;
    NSString *_modelProgressMessage;
}
@end

@implementation OnboardingViewController

- (instancetype)initWithPreferences:(ShortcutPreferences *)preferences monitor:(ShortcutMonitor *)monitor {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _preferences = preferences;
    _monitor = monitor;
    _modelPhase = BawanModelSetupNeedsDownload;
    _trialPhase = TrialPhase::Ready;

    BawanSurfaceView *root = BawanMakeWindowSurface(@"bawan-onboarding", NSMakeRect(0, 0, 720, 500));
    self.view = root;
    BawanChromeHeader header = BawanAddHeader(root, @"onboarding-header", @"onboarding-mascot");
    _mascot = header.mascot;

    BawanChromeFooter footer = BawanAddFooter(root, @"onboarding-footer");
    _primary = BawanAddFooterPrimary(footer.footer, @"onboarding-primary", @"",
        self, @selector(performPrimaryAction));
    _modelLicense = BawanAddFooterSecondary(footer.footer, @"onboarding-model-license", BawanModelLicenseTitle,
        self, @selector(openModelLicense:));
    _modelLicense.image = BawanSymbol(@"doc.text", @"", 13);
    _modelLicense.imagePosition = NSImageLeft;
    _modelLicense.imageHugsTitle = YES;
    _modelControl = BawanAddFooterSecondary(footer.footer, @"onboarding-model-control", @"",
        self, @selector(performModelAction:));
    _footerNote = BawanAddFooterHint(footer.footer, @"onboarding-footer-note", @"", _primary, _modelLicense);

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.identifier = @"onboarding-scroll";
    _scroll = scroll;
    scroll.borderType = NSNoBorder;
    BawanConfigurePaperScrollView(scroll);
    scroll.autohidesScrollers = NO;
    scroll.scrollerStyle = NSScroller.preferredScrollerStyle;
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
    NSTextField *detail = Label(@"Use your selection shortcut to translate text from any app, or open Bawan with its window shortcut.",
        BawanSetupBodySize, NSFontWeightRegular, BawanSecondaryText);
    NSStackView *hero = BawanSetupStack(@[title, detail], NSUserInterfaceLayoutOrientationVertical, 8);
    hero.identifier = @"onboarding-shortcut-intro";
    [title.widthAnchor constraintEqualToAnchor:hero.widthAnchor].active = YES;
    [detail.widthAnchor constraintEqualToAnchor:hero.widthAnchor].active = YES;
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObjects:hero, BawanSetupRule(), nil];
    for (auto action : BawanShortcutActions) {
        [views addObject:[self shortcutRow:action]];
        [views addObject:BawanSetupRule()];
    }
    _selectionSample = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 560, 44)];
    _selectionSample.identifier = @"onboarding-trial-sample";
    _selectionSample.translatesAutoresizingMaskIntoConstraints = NO;
    _selectionSample.string = @"A small step opens a new world.";
    _selectionSample.editable = NO;
    _selectionSample.selectable = YES;
    _selectionSample.richText = NO;
    _selectionSample.drawsBackground = NO;
    _selectionSample.font = [NSFont systemFontOfSize:BawanSetupBodySize weight:NSFontWeightMedium];
    _selectionSample.textColor = BawanColor(BawanText);
    _selectionSample.textContainerInset = NSMakeSize(0, 6);
    _selectionSample.textContainer.lineFragmentPadding = 0;
    _selectionSample.textContainer.widthTracksTextView = YES;
    [_selectionSample.heightAnchor constraintEqualToConstant:44].active = YES;
    [_selectionSample setAccessibilityLabel:@"Shortcut practice sentence"];
    _trialInstructions = Label(@"", BawanSetupBodySize, NSFontWeightRegular, BawanSecondaryText);
    _trialInstructions.identifier = @"onboarding-trial-instructions";
    _trialStatus = Label(@"", BawanSetupCaptionSize, NSFontWeightRegular, BawanSecondaryText);
    _trialStatus.identifier = @"onboarding-trial-status";
    NSStackView *trial = BawanSetupStack(@[_selectionSample, _trialInstructions, _trialStatus],
        NSUserInterfaceLayoutOrientationVertical, 6);
    trial.identifier = @"onboarding-selection-trial";
    for (NSView *view in trial.arrangedSubviews) [view.widthAnchor constraintEqualToAnchor:trial.widthAnchor].active = YES;
    _selectionTrial = trial;
    [views addObject:trial];
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

- (NSView *)shortcutRow:(bawan::ShortcutAction)action {
    NSTextField *name = Label(ShortcutActionTitle(action), BawanSetupRowTitleSize, NSFontWeightSemibold, BawanText);
    name.identifier = ShortcutID(action, @"title");
    NSTextField *status = Label(@"", BawanSetupCaptionSize, NSFontWeightRegular, BawanSecondaryText);
    status.identifier = ShortcutID(action, @"status");
    NSTextField *key = [[BawanSetupKeycap alloc] initWithFrame:NSZeroRect];
    key.translatesAutoresizingMaskIntoConstraints = NO;
    key.identifier = ShortcutID(action, @"key");
    NSTextField *presses = [[BawanSetupKeycap alloc] initWithFrame:NSZeroRect];
    presses.translatesAutoresizingMaskIntoConstraints = NO;
    presses.identifier = ShortcutID(action, @"presses");
    [NSLayoutConstraint activateConstraints:@[
        [key.widthAnchor constraintEqualToConstant:BawanSetupKeyWidth],
        [key.heightAnchor constraintEqualToConstant:BawanInputHeight],
        [presses.widthAnchor constraintEqualToConstant:BawanSetupCountWidth],
        [presses.heightAnchor constraintEqualToConstant:BawanInputHeight]
    ]];
    BawanActionButton *setup = BawanSetupButton(ShortcutID(action, @"setup"), @"Set Up…", BawanSetupActionWidth,
        self, @selector(setUpShortcut:));
    setup.tag = static_cast<NSInteger>(action);
    _shortcutRows.push_back({action, key, presses, status, setup});
    return BawanSetupInsetRow(ShortcutID(action, @"row"), name, status, @[key, presses, setup], 16, 12);
}

- (BOOL)showingModelStep { return IsModelStep(_modelPhase); }

- (void)setModelPhase:(BawanModelSetupPhase)phase message:(NSString *)message progress:(std::optional<double>)progress {
    BOOL changed = _modelPhase != phase;
    BOOL wasModelStep = [self showingModelStep];
    _modelPhase = phase;
    BOOL failed = phase == BawanModelSetupFailed || phase == BawanModelSetupResumableFailure;
    BOOL modelStep = IsModelStep(phase);
    const BawanModelPresentation presentation = BawanPresentModel(phase);

    _modelStep.hidden = !modelStep;
    _shortcutStep.hidden = modelStep;
    NSButton *trailingAction = nil;
    if (modelStep) trailingAction = _modelLicense;
    else if (phase == BawanModelSetupDownloading || phase == BawanModelSetupPaused) trailingAction = _modelControl;
    for (NSButton *button in @[_modelLicense, _modelControl]) button.hidden = button != trailingAction;
    _modelControl.title = presentation.actionTitle;

    _title.stringValue = failed ? @"Let’s Finish Setting Up" : @"Prepare Your Translator";
    _modelStatus.stringValue = presentation.status;
    _modelStatus.textColor = BawanColor(presentation.statusColor);
    _modelIcon.image = BawanSymbol(presentation.symbol, nil, 15);
    _modelIcon.contentTintColor = BawanColor(presentation.symbolColor);
    _modelMessage.stringValue = failed && message.length ? message :
        @"Bawan translates on your Mac with PLaMo 3 Translate. Review the model license, then download the model (about 573 MB).";
    _modelMessage.textColor = BawanColor(failed ? BawanError : BawanSecondaryText);
    // The shortcut step reports ModelStore's own words (checking, downloading,
    // verifying, loading), which already carry any percentage.
    _modelProgressMessage = modelStep ? nil : [message copy];
    [self refresh];
    if (wasModelStep != modelStep && self.view.window.visible) BawanSetupPresentPage(self.view, _scroll);
    if (changed && failed && message.length && self.view.window.visible) {
        NSAccessibilityPostNotificationWithUserInfo(NSApp, NSAccessibilityAnnouncementRequestedNotification, @{
            NSAccessibilityAnnouncementKey: message,
            NSAccessibilityPriorityKey: @(NSAccessibilityPriorityMedium)
        });
    }
}

- (void)updateFooter {
    if ([self showingModelStep]) {
        _primary.title = [BawanPresentModel(_modelPhase).actionTitle stringByAppendingString:@"  ⌘↵"];
        _primary.toolTip = nil;
        _footerNote.stringValue = @"The model downloads directly from PFN to your Mac.";
        return;
    }
    BOOL complete = self.selectionTrialComplete;
    _primary.title = complete ? @"Start Translating  ⌘↵" : @"Set Up Later  ⌘↵";
    _primary.toolTip = complete ? @"Start translating (⌘Return)" :
        @"Continue now and finish the shortcuts later in Settings (⌘Return)";
    _footerNote.stringValue = _modelProgressMessage ?: @"";
}

- (void)refresh {
    for (const ShortcutRow &row : _shortcutRows) {
        auto binding = [_preferences bindingForAction:row.action];
        ShortcutAvailability availability = binding.enabled ? [_monitor availabilityForAction:row.action] :
            ShortcutAvailabilityOff;
        const auto presentation = BawanPresentShortcut(availability);
        row.key.stringValue = ShortcutKeyLabel(binding);
        row.presses.stringValue = ShortcutPressCountTitle(binding.pressCount);
        row.status.stringValue = presentation.status;
        row.status.textColor = BawanColor(presentation.color);
        row.setup.hidden = availability == ShortcutAvailabilityAvailable;
        BawanApplyShortcutAction(row.setup, presentation, ShortcutActionTitle(row.action));
    }
    auto binding = [_preferences bindingForAction:bawan::ShortcutAction::TranslateSelection];
    BOOL ready = binding.enabled && [_monitor availabilityForAction:bawan::ShortcutAction::TranslateSelection] ==
        ShortcutAvailabilityAvailable;
    if (binding != _trialBinding || !ready || [self showingModelStep]) {
        [self resetSelectionTrial];
    }
    _trialBinding = binding;
    _selectionReady = ready;
    _selectionTrial.hidden = !ready;
    _trialInstructions.stringValue = [NSString stringWithFormat:@"Select the whole sentence above, then press %@ %@.",
        ShortcutKeyLabel(binding), binding.pressCount == 1 ? @"once" : @"twice"];
    _monitor.selectionTrialView = _active && ready && ![self showingModelStep] ? _selectionSample : nil;
    [self updateFooter];
    [self.view layoutSubtreeIfNeeded];
}

- (void)setActive:(BOOL)active {
    _active = active;
    _monitor.configurationActive = active;
    if (active) {
        [_monitor refresh];
        [self refresh];
    } else {
        _monitor.selectionTrialView = nil;
        [_mascot resetHoverAnimation];
        [_heroMascot resetHoverAnimation];
    }
}

- (void)willLeavePanelPage {
    if (_trialPhase != TrialPhase::Translating) return;
    [self cancelSelectionTrial];
    if (self.onSelectionTrialInterrupted) self.onSelectionTrialInterrupted();
}

- (NSString *)selectionTrialText { return _selectionSample.string; }
- (NSString *)selectionTrialOutput { return _trialOutput; }
- (bawan::Direction)selectionTrialDirection { return _trialDirection; }
- (BOOL)selectionTrialComplete { return _trialPhase == TrialPhase::Complete && _selectionReady; }

- (void)resetSelectionTrial {
    ++_trialAttempt;
    _trialPhase = TrialPhase::Ready;
    _trialOutput = nil;
    _trialStatus.stringValue = @"";
    _trialStatus.hidden = YES;
}

- (BOOL)isSelectionTrialText:(NSString *)text {
    if (!_active) return NO;
    [self refresh];
    return _selectionReady && ![self showingModelStep] &&
        _selectionSample.window.isKeyWindow && _selectionSample.window.firstResponder == _selectionSample &&
        NSEqualRanges(_selectionSample.selectedRange, NSMakeRange(0, _selectionSample.string.length)) &&
        [text isEqualToString:_selectionSample.string];
}

- (NSUInteger)beginSelectionTrial {
    if (![self isSelectionTrialText:_selectionSample.string] || _trialPhase != TrialPhase::Ready) return 0;
    ++_trialAttempt;
    _trialPhase = TrialPhase::Translating;
    _trialStatus.stringValue = @"Translating… The model may need to finish preparing first.";
    _trialStatus.textColor = BawanColor(BawanSecondaryText);
    _trialStatus.hidden = NO;
    [self.view layoutSubtreeIfNeeded];
    return _trialAttempt;
}

- (BOOL)isSelectionTrialCurrent:(NSUInteger)attempt {
    const auto binding = [_preferences bindingForAction:bawan::ShortcutAction::TranslateSelection];
    return attempt && attempt == _trialAttempt &&
        ![self showingModelStep] && _trialPhase == TrialPhase::Translating &&
        binding == _trialBinding && binding.enabled &&
        [_monitor availabilityForAction:bawan::ShortcutAction::TranslateSelection] == ShortcutAvailabilityAvailable;
}

- (BOOL)finishSelectionTrial:(NSUInteger)attempt output:(NSString *)output direction:(bawan::Direction)direction {
    if (![self isSelectionTrialCurrent:attempt]) return NO;
    BOOL complete = [output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
    _trialPhase = complete ? TrialPhase::Complete : TrialPhase::Ready;
    _trialOutput = complete ? [output copy] : nil;
    _trialDirection = direction;
    _trialStatus.stringValue = complete ? @"Shortcut tried successfully. Your translation is ready." :
        @"The translation didn’t finish. Select the sentence and try the shortcut again.";
    _trialStatus.textColor = BawanColor(complete ? BawanSuccess : BawanWarning);
    _trialStatus.hidden = NO;
    [self updateFooter];
    [self.view layoutSubtreeIfNeeded];
    return complete;
}

- (void)cancelSelectionTrial {
    if (_trialPhase != TrialPhase::Translating) return;
    [self resetSelectionTrial];
    [self updateFooter];
}

- (void)discardSelectionTrialResult {
    if (_trialPhase != TrialPhase::Complete) return;
    [self resetSelectionTrial];
    [self updateFooter];
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

// The footer button and ⌘Return: set up the model on the model step, otherwise leave.
- (void)performPrimaryAction {
    if ([self showingModelStep]) {
        if (self.onModelSetup) self.onModelSetup();
    } else if (self.onFinish) {
        self.onFinish();
    }
}
- (void)performModelAction:(id)sender { if (self.onModelSetup) self.onModelSetup(); }
- (void)openModelLicense:(id)sender { if (self.onModelLicense) self.onModelLicense(); }

@end
