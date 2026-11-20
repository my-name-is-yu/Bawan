#import "AppDelegate.h"
#import "ModelStore.h"
#import "ModelSetupState.h"
#import "ShortcutMonitor.h"
#import "SelectionReader.h"
#import "TranslationPanel.h"
#import "SettingsViewController.h"
#import "AppUpdater.h"
#import "OnboardingViewController.h"
#import <ServiceManagement/ServiceManagement.h>
#import <CoreFoundation/CoreFoundation.h>

#include "TranslationEngine.h"
#include "EngineEventMailbox.h"
#include <memory>

enum class StatusOwner { None, ModelStatus, TranslationOutcome, ShortcutWarning };

@interface AppDelegate () <NSMenuDelegate> {
    NSStatusItem *_statusItem;
    NSMenuItem *_modelItem;
    NSMenuItem *_shortcutItem;
    NSMenuItem *_panelShortcutItem;
    NSMenuItem *_retryItem;
    NSMenuItem *_checkUpdatesItem;
    NSMenuItem *_mainCheckUpdatesItem;
    AppUpdater *_updater;
    SettingsViewController *_settingsViewController;
    OnboardingViewController *_onboardingViewController;
    NSUserDefaults *_defaults;
    ShortcutPreferences *_shortcutPreferences;
    TranslationPanel *_translationPanel;
    ModelStore *_modelStore;
    ShortcutMonitor *_shortcut;
    dispatch_source_t _memoryPressure;
    std::unique_ptr<bawan::TranslationEngine> _engine;
    uint64_t _activeRequestId;
    uint64_t _engineGeneration;
    NSString *_pendingText;
    bawan::Direction _pendingDirection;
    NSString *_pendingTrialText;
    NSUInteger _selectionTrialAttempt;
    BOOL _warmUpWhenAvailable;
    BOOL _busy;
    BOOL _terminating;
    BOOL _terminationReplyPending;
    BOOL _terminationReplyCancelled;
    uint64_t _terminationReplyGeneration;
    StatusOwner _statusOwner;
    BawanModelState _model;
    NSString *_memoryProbeDirectory;
}
- (void)refreshUpdateControls;
- (void)setTranslationBusy:(BOOL)busy;
- (BOOL)canAcceptTranslation;
- (void)scheduleEngineEventDrain:(std::shared_ptr<bawan::EngineEventMailbox>)mailbox generation:(uint64_t)generation;
- (void)updaterStateDidChange;
- (void)cancelDeferredTermination;
- (void)replyToDeferredTerminationAfterResultInSelectionTrial:(BOOL)selectionTrial;
- (void)enqueueTerminationReply:(BOOL)shouldTerminate;
- (void)sendTerminationReply:(BOOL)shouldTerminate;
@end

static NSString *const BawanOnboardingCompletedKey = @"firstLaunchShown";
static NSString *const BawanModelLicenseAcceptedKey = @"modelLicenseNoticeShown20261109";

@implementation AppDelegate

- (instancetype)init {
    self = [super init];
    if (self) {
        _defaults = NSUserDefaults.standardUserDefaults;
    }
    return self;
}

- (BOOL)hasVerifiedModelFile { return _model.hasVerifiedFile(); }
- (BOOL)modelFailed { return _model.failed(); }
- (NSURL *)modelURL { return _model.url(); }
- (NSString *)modelStatus { return _model.message(); }

static NSString *StringFromUTF8(const std::string &text) {
    return [[NSString alloc] initWithBytes:text.data() length:text.size()
                                 encoding:NSUTF8StringEncoding] ?: @"Unable to display the text.";
}

static void PerformInCommonAndModalRunLoopModes(dispatch_block_t block) {
    CFRunLoopRef runLoop = CFRunLoopGetMain();
    NSArray<NSString *> *modes = @[(__bridge NSString *)kCFRunLoopCommonModes, NSModalPanelRunLoopMode];
    CFRunLoopPerformBlock(runLoop, (__bridge CFArrayRef)modes, block);
    CFRunLoopWakeUp(runLoop);
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _shortcutPreferences = [[ShortcutPreferences alloc] init];
    _updater = [[AppUpdater alloc] init];
    [self buildMenus];
    _translationPanel = [[TranslationPanel alloc] init];
    __weak AppDelegate *weakSelf = self;
    _updater.onStateChanged = ^{ [weakSelf updaterStateDidChange]; };
    _translationPanel.onTranslate = ^(NSString *text, bawan::Direction direction) {
        [weakSelf translateText:text direction:direction];
    };
    _translationPanel.onCancel = ^{ [weakSelf cancelTranslation]; };
    _translationPanel.onClose = ^{ [weakSelf cancelTranslation]; };
    _translationPanel.onSettings = ^{ [weakSelf openSettings:nil]; };

    _memoryPressure = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, dispatch_get_main_queue());
    dispatch_source_set_event_handler(_memoryPressure, ^{ [weakSelf releaseEngineMemory]; });
    dispatch_resume(_memoryPressure);

    _modelStore = [[ModelStore alloc] init];
    _modelStore.onStateChange = ^(ModelStoreState state) {
        AppDelegate *owner = weakSelf;
        if (owner && !owner->_terminating) [owner modelDownloadStateDidChange:state];
    };
    _modelStore.onProgress = ^(double progress, NSString *message) {
        AppDelegate *owner = weakSelf;
        if (owner && !owner->_terminating) [owner modelFileDidProgress:progress message:message];
    };
    _modelStore.onReady = ^(NSURL *fileURL) {
        AppDelegate *owner = weakSelf;
        if (owner && !owner->_terminating) [owner modelFileDidBecomeReady:fileURL];
    };
    _modelStore.onError = ^(NSString *message) {
        AppDelegate *owner = weakSelf;
        if (owner && !owner->_terminating) [owner modelFileDidFail:message];
    };

    SelectionReader *selectionReader = [SelectionReader new];
    _shortcut = [[ShortcutMonitor alloc] initWithPreferences:_shortcutPreferences selectionReader:selectionReader];
    selectionReader.onText = ^(NSString *text) {
        AppDelegate *owner = weakSelf;
        if (!owner || owner->_terminating) return;
        [owner handleSelectionText:text];
    };
    selectionReader.onProblem = ^(NSString *message) {
        AppDelegate *owner = weakSelf;
        if (!owner || owner->_terminating) return;
        [owner handleShortcutProblem:message];
    };
    _shortcut.onSelectionTrial = ^(NSString *text) {
        AppDelegate *owner = weakSelf;
        if (owner && !owner->_terminating) [owner handleSelectionTrialText:text];
    };
    _shortcut.onOpenPanel = ^{
        AppDelegate *owner = weakSelf;
        if (owner && !owner->_terminating) [owner openTranslation:nil];
    };
    _shortcut.onAvailabilityChanged = ^{
        AppDelegate *owner = weakSelf;
        if (owner && !owner->_terminating) [owner updateShortcutItem];
    };
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(shortcutPreferencesDidChange:)
        name:BawanShortcutsDidChangeNotification object:_shortcutPreferences];
    [_shortcut start];
    [self updateShortcutItem];
    [self updateStatus];
    _memoryProbeDirectory = NSProcessInfo.processInfo.environment[@"BAWAN_MEMORY_PROBE"];
    if (_memoryProbeDirectory.length) {
        [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(memoryProbeTick:)
                                      userInfo:nil repeats:YES];
    } else {
        [self startInitialSetup];
    }
    [_updater start];
}

- (void)memoryProbeWrite:(NSString *)value name:(NSString *)name {
    [value writeToFile:[_memoryProbeDirectory stringByAppendingPathComponent:name]
           atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)memoryProbeTick:(NSTimer *)timer {
    NSString *path = [_memoryProbeDirectory stringByAppendingPathComponent:@"command"];
    NSString *command = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!command) return;
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    if ([command isEqualToString:@"translation"]) [_translationPanel showForManualInput];
    else if ([command isEqualToString:@"settings"]) [self openSettings:nil];
    else if ([command isEqualToString:@"setup"]) [self showOnboarding];
    else if ([command isEqualToString:@"close"]) [_translationPanel close];
    else if ([command isEqualToString:@"prepare"]) [self prepareModel];
    else if ([command isEqualToString:@"model"]) {
        [self memoryProbeWrite:[self hasVerifiedModelFile] ? @"ready" :
            ([self modelFailed] ? @"error" : @"waiting") name:@"reply"];
        return;
    } else if ([command isEqualToString:@"translate"]) {
        [self translateText:@"Hello. How are you?" direction:bawan::Direction::EnglishToJapanese];
    } else if (![command isEqualToString:@"ping"]) {
        [self memoryProbeWrite:@"error" name:@"reply"];
        return;
    }
    [self memoryProbeWrite:@"ok" name:@"reply"];
}

- (void)modelDownloadStateDidChange:(ModelStoreState)state {
    switch (state) {
        case ModelStoreDownloading: _model.fileDownloading(); break;
        case ModelStorePaused: _model.filePaused(); break;
        case ModelStoreVerifying: _model.fileVerifying(); break;
        case ModelStoreIdle:
        case ModelStoreReady:
        case ModelStoreFailed: return;
    }
    [self updateStatus];
}

- (void)modelFileDidProgress:(double)progress message:(NSString *)message {
    _model.fileProgress(progress, message);
    [self updateStatus];
}

- (void)modelFileDidBecomeReady:(NSURL *)fileURL {
    _model.fileReady(fileURL);
    if (_pendingTrialText && [_onboardingViewController isSelectionTrialCurrent:_selectionTrialAttempt]) {
        [self translateText:_pendingTrialText direction:bawan::Direction::Automatic trialAttempt:_selectionTrialAttempt];
    } else {
        if (_pendingTrialText) [self cancelTranslationKeepingPendingSelection:YES];
        if (![self submitPendingTranslationIfReady] && !_pendingText && _warmUpWhenAvailable) [self warmUpEngine];
    }
    [self updateStatus];
}

- (void)modelFileDidFail:(NSString *)message {
    [_onboardingViewController cancelSelectionTrial];
    _selectionTrialAttempt = 0;
    _pendingTrialText = nil;
    _model.fileFailed(message, _modelStore.canResume);
    _pendingText = nil;
    _warmUpWhenAvailable = NO;
    [self setTranslationBusy:NO];
    _activeRequestId = 0;
    [self updateStatus];
}

- (BOOL)needsOnboarding { return !_memoryProbeDirectory.length && ![_defaults boolForKey:BawanOnboardingCompletedKey]; }

- (void)markOnboardingComplete {
    if ([self needsOnboarding]) [_defaults setBool:YES forKey:BawanOnboardingCompletedKey];
}

- (void)startInitialSetup {
    if ([self needsOnboarding]) {
        [self showOnboarding];
        if ([_defaults boolForKey:BawanModelLicenseAcceptedKey]) [self beginModelSetup];
    } else {
        [self beginModelSetup];
    }
}

- (void)beginModelSetup {
    if ([_defaults boolForKey:BawanModelLicenseAcceptedKey]) {
        [self prepareModel];
        return;
    }
    __weak AppDelegate *weakSelf = self;
    [self requestModelLicenseAcceptance:^(BOOL accepted) {
        AppDelegate *owner = weakSelf;
        if (!accepted || !owner || owner->_terminating) return;
        [owner->_defaults setBool:YES forKey:BawanModelLicenseAcceptedKey];
        [owner prepareModel];
    }];
}

// A first setup prepares the model; any later request revalidates it from scratch.
- (void)prepareModel {
    if (!_model.setupNotStarted()) {
        [self retryModel:nil];
        return;
    }
    _model.beginPreparing();
    [self updateStatus];
    [_modelStore prepare];
}

- (void)showOnboarding {
    __weak AppDelegate *weakSelf = self;
    if (!_onboardingViewController) {
        _onboardingViewController = [[OnboardingViewController alloc]
            initWithPreferences:_shortcutPreferences monitor:_shortcut];
        _onboardingViewController.onModelSetup = ^{ [weakSelf performModelAction:nil]; };
        _onboardingViewController.onModelLicense = ^{ [weakSelf showModelLicense:weakSelf]; };
        _onboardingViewController.onFinish = ^{ [weakSelf finishOnboardingFromShortcuts]; };
        _onboardingViewController.onSelectionTrialInterrupted = ^{
            AppDelegate *owner = weakSelf;
            if (owner && owner->_selectionTrialAttempt) [owner cancelTranslationKeepingPendingSelection:YES];
        };
    }
    [self pushModelStateToPage:_onboardingViewController];
    [_translationPanel showOnboarding:_onboardingViewController onBack:^{ [weakSelf finishOnboarding]; }];
}

// The shortcut step's button: leave for the translator even while the model is
// still downloading. The translator shows preparation and translates once ready.
- (void)finishOnboardingFromShortcuts {
    if (!_model.canFinishSetup()) return;
    [self enterTranslatorFromOnboarding];
    if (!_busy) [self warmUpEngine];
}

- (void)enterTranslatorFromOnboarding {
    [_onboardingViewController refresh];
    if (_selectionTrialAttempt) [self cancelTranslationKeepingPendingSelection:YES];
    [self markOnboardingComplete];
    if (_onboardingViewController.selectionTrialComplete) {
        // Accepting the successful practice result explicitly replaces the old selection.
        _pendingText = nil;
        [self setTranslationBusy:NO];
        NSString *text = _onboardingViewController.selectionTrialText;
        NSString *output = _onboardingViewController.selectionTrialOutput;
        const auto direction = _onboardingViewController.selectionTrialDirection;
        [_translationPanel showForSelection:text];
        [_translationPanel setOutput:output direction:direction];
    }
    [_translationPanel showForManualInput];
    if (![self submitPendingTranslationIfReady]) [self updateStatus];
}

// Escape leaves onboarding: it finishes once the model is ready, otherwise it just closes.
- (void)finishOnboarding {
    if (!_model.canEnterTranslator()) {
        [_translationPanel close];
        return;
    }
    [self enterTranslatorFromOnboarding];
}

- (void)pushModelStateToPage:(id<BawanModelSetupDisplay>)page {
    [page setModelPhase:_model.phase() message:_model.message() progress:_model.progress()];
}

// Hidden pages are brought up to date when they are shown.
- (void)refreshSetupPages {
    switch (_translationPanel.currentPage) {
        case BawanPanelPageOnboarding: [self pushModelStateToPage:_onboardingViewController]; break;
        case BawanPanelPageSettings: [self pushModelStateToPage:_settingsViewController]; break;
        case BawanPanelPageTranslation: break;
    }
}

- (NSMenuItem *)menuItem:(NSString *)title action:(SEL)action key:(NSString *)key {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    item.target = self;
    return item;
}

- (NSAlert *)modelLicenseAlertForSetup:(BOOL)forSetup {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Built with PLaMo";
    alert.informativeText = @"Bawan uses PLaMo 3 Translate 0.8B under the PLaMo Community License, separately from Bawan’s MIT License. Using the model is subject to PFN’s terms.\n\n"
        "Personal and non-commercial use, including academic use, is free without registration.\n\n"
        "Commercial use includes internal business use. If you or your affiliates’ annual revenue or sales does not exceed JPY 1 billion, register with PFN before commercial use. Above that threshold, a separate commercial agreement is required.\n\n"
        "The model (~573 MB) downloads directly from PFN to your Mac. Review the official terms for your use.";
    [alert addButtonWithTitle:forSetup ? @"Continue to Model Setup" : @"Done"];
    if (forSetup) [alert addButtonWithTitle:@"Not Now"];
    NSStackView *links = [[NSStackView alloc] init];
    links.orientation = NSUserInterfaceLayoutOrientationVertical;
    links.alignment = NSLayoutAttributeLeading;
    links.spacing = 8;
    for (NSArray<NSString *> *link in @[
        @[@"Official license (日本語)", @"https://plamo.preferredai.jp/info/plamo-community-license-ja"],
        @[@"Official license (English)", @"https://plamo.preferredai.jp/info/plamo-community-license-en"],
        @[@"Commercial use registration", @"https://forms.gle/mTL8tBLrMYXKNZD56"]]) {
        NSButton *button = [NSButton buttonWithTitle:link[0] target:self action:@selector(openModelLicenseLink:)];
        button.identifier = link[1];
        [links addArrangedSubview:button];
    }
    links.frame = NSMakeRect(0, 0, 360, 96);
    alert.accessoryView = links;
    return alert;
}

// Attach to the visible panel as a sheet so model progress keeps updating;
// fall back to an app-modal alert when the license is opened from the menu.
- (void)presentModelLicenseAlert:(NSAlert *)alert completion:(void (^)(NSModalResponse response))completion {
    [NSApp activateIgnoringOtherApps:YES];
    NSWindow *window = _translationPanel.window;
    if (window.visible && !window.attachedSheet) {
        [alert beginSheetModalForWindow:window completionHandler:completion];
    } else {
        completion([alert runModal]);
    }
}

- (void)showModelLicense:(id)sender {
    [self presentModelLicenseAlert:[self modelLicenseAlertForSetup:NO] completion:^(NSModalResponse) {}];
}

- (void)requestModelLicenseAcceptance:(void (^)(BOOL accepted))completion {
    [self presentModelLicenseAlert:[self modelLicenseAlertForSetup:YES] completion:^(NSModalResponse response) {
        completion(response == NSAlertFirstButtonReturn);
    }];
}

- (void)openModelLicenseLink:(NSButton *)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:sender.identifier]];
}

- (void)buildMenus {
    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    NSURL *iconURL = [NSBundle.mainBundle URLForResource:@"StatusItemTemplate" withExtension:@"pdf"];
    NSImage *image = iconURL ? [[NSImage alloc] initWithContentsOfURL:iconURL] : nil;
    if (!image) image = [NSImage imageWithSystemSymbolName:@"character.bubble" accessibilityDescription:@"Bawan Translator"];
    if (image) {
        image.size = NSMakeSize(20, 20);
        image.accessibilityDescription = @"Bawan Translator";
        [image setTemplate:YES];
        _statusItem.button.image = image;
    } else {
        _statusItem.button.title = @"L";
    }
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Bawan"];
    menu.autoenablesItems = NO;
    menu.delegate = self;
    _modelItem = [self menuItem:@"Preparing the model…" action:NULL key:@""];
    _modelItem.enabled = NO;
    [menu addItem:_modelItem];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self menuItem:@"Open Translator" action:@selector(openTranslation:) key:@""]];
    _shortcutItem = [self menuItem:@"Translate with Double ⌘C" action:@selector(toggleShortcut:) key:@""];
    _shortcutItem.tag = static_cast<NSInteger>(bawan::ShortcutAction::TranslateSelection);
    [menu addItem:_shortcutItem];
    _panelShortcutItem = [self menuItem:@"Open Translator with Double ⌥T" action:@selector(toggleShortcut:) key:@""];
    _panelShortcutItem.tag = static_cast<NSInteger>(bawan::ShortcutAction::OpenPanel);
    [menu addItem:_panelShortcutItem];
    _retryItem = [self menuItem:@"Retry Model Setup" action:@selector(performModelAction:) key:@""];
    _retryItem.hidden = YES;
    [menu addItem:_retryItem];
    [menu addItem:[self menuItem:@"Settings…" action:@selector(openSettings:) key:@","]];
    [menu addItem:[self menuItem:@"Model License…" action:@selector(showModelLicense:) key:@""]];
#if BAWAN_ENABLE_UPDATES
    _checkUpdatesItem = [self menuItem:@"Check for Updates…" action:@selector(checkForUpdates:) key:@""];
    [menu addItem:_checkUpdatesItem];
#endif
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self menuItem:@"Quit Bawan" action:@selector(quit:) key:@"q"]];
    _statusItem.menu = menu;

    // Native editing commands are required when the nonactivating panel becomes key.
    NSMenu *main = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"Bawan" action:NULL keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Bawan"];
    [appMenu addItem:[self menuItem:@"Settings…" action:@selector(openSettings:) key:@","]];
    [appMenu addItem:[self menuItem:@"Model License…" action:@selector(showModelLicense:) key:@""]];
#if BAWAN_ENABLE_UPDATES
    _mainCheckUpdatesItem = [self menuItem:@"Check for Updates…" action:@selector(checkForUpdates:) key:@""];
    [appMenu addItem:_mainCheckUpdatesItem];
#endif
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItem:[self menuItem:@"Quit Bawan" action:@selector(quit:) key:@"q"]];
    appItem.submenu = appMenu;
    [main addItem:appItem];
    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:NULL keyEquivalent:@""];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    NSArray<NSString *> *titles = @[@"Undo", @"Redo", @"Cut", @"Copy", @"Paste", @"Select All"];
    NSArray<NSString *> *selectors = @[@"undo:", @"redo:", @"cut:", @"copy:", @"paste:", @"selectAll:"];
    NSArray<NSString *> *keys = @[@"z", @"z", @"x", @"c", @"v", @"a"];
    for (NSUInteger i = 0; i < titles.count; ++i) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:titles[i]
            action:NSSelectorFromString(selectors[i]) keyEquivalent:keys[i]];
        if (i == 1) item.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
        [edit addItem:item];
    }
    editItem.submenu = edit;
    [main addItem:editItem];
    NSApp.mainMenu = main;
    [self refreshUpdateControls];
}

- (void)refreshUpdateControls {
    _checkUpdatesItem.enabled = _updater.canCheckForUpdates;
    _mainCheckUpdatesItem.enabled = _updater.canCheckForUpdates;
    [_settingsViewController setUpdatesAvailable:_updater.available canCheck:_updater.canCheckForUpdates
        automaticallyChecks:_updater.automaticallyChecksForUpdates];
}

- (void)updaterStateDidChange {
    [self refreshUpdateControls];
    if (!_updater.installingUpdate) [self cancelDeferredTermination];
}

- (void)checkForUpdates:(id)sender { [_updater checkForUpdates:sender]; }

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    return item.action != @selector(checkForUpdates:) || _updater.canCheckForUpdates;
}

- (void)setTranslationBusy:(BOOL)busy {
    _busy = busy;
    _updater.translationBusy = busy;
}

- (BOOL)canAcceptTranslation {
    return !_terminating && !_updater.installingUpdate;
}

- (void)updateStatus {
    [self refreshSetupPages];
    _modelItem.title = _model.message();
    BOOL failed = [self modelFailed];
    BOOL available = [self hasVerifiedModelFile];
    const BawanModelSetupPhase phase = _model.phase();
    const BOOL hasModelAction = failed || phase == BawanModelSetupDownloading || phase == BawanModelSetupPaused;
    _retryItem.title = BawanPresentModel(phase).actionTitle;
    _retryItem.hidden = !hasModelAction;
    _retryItem.enabled = hasModelAction;
    _statusItem.button.toolTip = [@"Bawan — " stringByAppendingString:_modelItem.title];
    if (_model.phase() != BawanModelSetupReady) {
        [self showStatus:_modelItem.title kind:failed ? BawanStatusError : BawanStatusInformation
                   owner:StatusOwner::ModelStatus];
        return;
    }
    switch (_statusOwner) {
        case StatusOwner::ModelStatus:
            [self showStatus:@"" kind:BawanStatusInformation owner:StatusOwner::None];
            break;
        case StatusOwner::None:
        case StatusOwner::TranslationOutcome:
        case StatusOwner::ShortcutWarning:
            [_translationPanel setAvailable:available busy:_busy];
            break;
    }
}

- (void)showStatus:(NSString *)message kind:(BawanStatusKind)kind owner:(StatusOwner)owner {
    _statusOwner = message.length ? owner : StatusOwner::None;
    [_translationPanel setAvailable:[self hasVerifiedModelFile] busy:_busy status:message kind:kind];
}

- (void)handleShortcutProblem:(NSString *)message {
    [self updateShortcutItem];
    [_translationPanel showWithoutChangingInput];
    [self showStatus:message kind:BawanStatusWarning owner:StatusOwner::ShortcutWarning];
    _statusItem.button.toolTip = message;
}

- (void)updateShortcutItem {
    NSMutableArray<NSString *> *instructions = [NSMutableArray array];
    BOOL needsPermission = NO;
    for (NSMenuItem *item in @[_shortcutItem, _panelShortcutItem]) {
        auto action = static_cast<bawan::ShortcutAction>(item.tag);
        auto binding = [_shortcutPreferences bindingForAction:action];
        ShortcutAvailability availability = [_shortcut availabilityForAction:action];
        item.state = binding.enabled ? NSControlStateValueOn : NSControlStateValueOff;
        NSString *verb = ShortcutActionTitle(action);
        NSString *suffix = @"";
        if (binding.enabled && availability != ShortcutAvailabilityAvailable) {
            suffix = availability == ShortcutAvailabilityFailed ? @" (monitoring unavailable)" : @" (permission required)";
            needsPermission = YES;
        }
        item.title = [NSString stringWithFormat:@"%@ — %@%@", verb, ShortcutBindingLabel(binding), suffix];
        if (binding.enabled && availability == ShortcutAvailabilityAvailable) {
            [instructions addObject:[NSString stringWithFormat:@"%@: %@", verb, ShortcutBindingLabel(binding)]];
        }
    }
    if (needsPermission) [instructions addObject:@"Manage shortcut permissions in Settings."];
    [_translationPanel setShortcutInstructions:[instructions componentsJoinedByString:@" · "]];
    const BOOL cancelTrial = _selectionTrialAttempt &&
        ![_onboardingViewController isSelectionTrialCurrent:_selectionTrialAttempt];
    const BOOL onboardingUpdatedByCancellation = cancelTrial && _translationPanel.currentPage == BawanPanelPageOnboarding;
    if (cancelTrial) [self cancelTranslationKeepingPendingSelection:YES];
    [_settingsViewController refresh];
    if (!onboardingUpdatedByCancellation) [_onboardingViewController refresh];
}

- (void)shortcutPreferencesDidChange:(NSNotification *)notification { [self updateShortcutItem]; }

- (void)menuWillOpen:(NSMenu *)menu {
    [_shortcut refresh];
    [self updateShortcutItem];
}

- (void)ensureEngine {
    NSURL *modelURL = _model.url();
    if (_engine || !modelURL || _terminating) return;
    const uint64_t generation = ++_engineGeneration;
    __weak AppDelegate *weakSelf = self;
    auto mailbox = std::make_shared<bawan::EngineEventMailbox>();
    _engine = std::make_unique<bawan::TranslationEngine>(
        std::string(modelURL.fileSystemRepresentation), [weakSelf, generation, mailbox](bawan::EngineEvent event) {
            if (!mailbox->push(std::move(event))) return;
            @autoreleasepool {
                AppDelegate *owner = weakSelf;
                if (owner) [owner scheduleEngineEventDrain:mailbox generation:generation];
            }
        });
}

- (void)scheduleEngineEventDrain:(std::shared_ptr<bawan::EngineEventMailbox>)mailbox generation:(uint64_t)generation {
    __weak AppDelegate *weakSelf = self;
    PerformInCommonAndModalRunLoopModes(^{
        @autoreleasepool {
            AppDelegate *owner = weakSelf;
            const auto events = mailbox->drain();
            if (owner && !owner->_terminating && owner->_engineGeneration == generation) {
                for (const auto &queued : events) [owner handleEngineEvent:queued];
            }
        }
    });
}

- (void)warmUpEngine {
    if (_terminating) return;
    _warmUpWhenAvailable = ![self hasVerifiedModelFile];
    [self ensureEngine];
    if (_engine) _engine->warmUp();
}

- (void)queueTranslation:(NSString *)text direction:(bawan::Direction)direction {
    if (![self canAcceptTranslation]) return;
    _pendingText = [text copy];
    _pendingDirection = direction;
    _activeRequestId = 0;
    [self setTranslationBusy:YES];
    [_translationPanel setOutput:@"" direction:bawan::Direction::Automatic];
    [self updateStatus];
}

- (BOOL)submitPendingTranslationIfReady {
    if (![self canAcceptTranslation]) return NO;
    if (!_pendingText || [self needsOnboarding] || ![self hasVerifiedModelFile]) return NO;
    [self translateText:_pendingText direction:_pendingDirection];
    return YES;
}

- (void)translateText:(NSString *)text direction:(bawan::Direction)direction {
    if (![self canAcceptTranslation]) return;
    if (_selectionTrialAttempt) [self cancelTranslationKeepingPendingSelection:YES];
    [self translateText:text direction:direction trialAttempt:0];
}

- (void)translateText:(NSString *)text direction:(bawan::Direction)direction trialAttempt:(NSUInteger)attempt {
    if (![self canAcceptTranslation]) return;
    _selectionTrialAttempt = attempt;
    if (![self hasVerifiedModelFile]) {
        if ([self modelFailed]) {
            [_onboardingViewController finishSelectionTrial:attempt output:nil direction:direction];
            _selectionTrialAttempt = 0;
            [self updateStatus];
            return;
        }
        if (attempt) {
            _pendingTrialText = [text copy];
            _activeRequestId = 0;
            [self setTranslationBusy:YES];
            [self updateStatus];
        } else {
            [self queueTranslation:text direction:direction];
        }
        return;
    }
    if (attempt) {
        _pendingTrialText = nil;
    } else {
        [self markOnboardingComplete];
        _pendingText = nil;
    }
    _warmUpWhenAvailable = NO;
    [self ensureEngine];
    const char *utf8 = text.UTF8String;
    if (!utf8) return;
    _activeRequestId = _engine->translate(std::string(utf8, [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]), direction);
    [self setTranslationBusy:YES];
    if (!attempt) {
        [_translationPanel setOutput:@"" direction:bawan::Direction::Automatic];
        [self showStatus:@"" kind:BawanStatusInformation owner:StatusOwner::None];
    }
}

- (void)handleEngineEvent:(const bawan::EngineEvent &)event {
    using Kind = bawan::EngineEvent::Kind;
    if (_memoryProbeDirectory.length) {
        if (event.kind == Kind::Complete) [self memoryProbeWrite:@"complete" name:@"engine"];
        else if (event.kind == Kind::Idle) [self memoryProbeWrite:@"idle" name:@"engine"];
        else if (event.kind == Kind::Error || event.kind == Kind::Cancelled)
            [self memoryProbeWrite:@"error" name:@"engine"];
    }
    if (event.requestId == 0) {
        if (event.kind == Kind::Idle) return;
        if (event.kind == Kind::Loading) _model.engineLoading();
        else if (event.kind == Kind::Ready || event.kind == Kind::Cancelled) _model.engineIdle();
        else if (event.kind == Kind::Error) _model.engineFailed(StringFromUTF8(event.text));
        [self updateStatus];
        return;
    }
    if (event.requestId != _activeRequestId) return;
    if (_selectionTrialAttempt) {
        const NSUInteger attempt = _selectionTrialAttempt;
        if (![_onboardingViewController isSelectionTrialCurrent:attempt]) {
            [self cancelTranslationKeepingPendingSelection:YES];
            return;
        }
        if (event.kind == Kind::Complete || event.kind == Kind::Cancelled || event.kind == Kind::Error) {
            [self setTranslationBusy:_pendingText != nil];
            _activeRequestId = 0;
            _selectionTrialAttempt = 0;
            NSString *output = event.kind == Kind::Complete && !event.truncated ?
                [[NSString alloc] initWithBytes:event.text.data() length:event.text.size()
                    encoding:NSUTF8StringEncoding] : nil;
            [_onboardingViewController finishSelectionTrial:attempt output:output direction:event.direction];
            [self updateStatus];
            [self replyToDeferredTerminationAfterResultInSelectionTrial:YES];
        }
        return;
    }
    switch (event.kind) {
        case Kind::Text:
            [_translationPanel setOutput:StringFromUTF8(event.text) direction:event.direction];
            break;
        case Kind::Complete:
            [self setTranslationBusy:NO];
            _activeRequestId = 0;
            [_translationPanel setOutput:StringFromUTF8(event.text) direction:event.direction];
            [self showStatus:event.truncated ?
                @"Output limit reached. The translation is incomplete. Select less text and try again." : @""
                        kind:event.truncated ? BawanStatusWarning : BawanStatusInformation
                       owner:StatusOwner::TranslationOutcome];
            break;
        case Kind::Cancelled:
            [self setTranslationBusy:NO];
            _activeRequestId = 0;
            [self showStatus:@"Translation cancelled" kind:BawanStatusInformation owner:StatusOwner::TranslationOutcome];
            break;
        case Kind::Error:
            [self setTranslationBusy:NO];
            _activeRequestId = 0;
            [self showStatus:StringFromUTF8(event.text) kind:BawanStatusError owner:StatusOwner::TranslationOutcome];
            break;
        default: break;
    }
    if (event.kind == Kind::Complete || event.kind == Kind::Cancelled || event.kind == Kind::Error) {
        [self replyToDeferredTerminationAfterResultInSelectionTrial:NO];
    }
}

- (void)cancelTranslationKeepingPendingSelection:(BOOL)keepSelection {
    const BOOL cancellingActiveRequest = _activeRequestId != 0;
    const BOOL cancellingTrial = _selectionTrialAttempt != 0;
    [_onboardingViewController cancelSelectionTrial];
    _selectionTrialAttempt = 0;
    _pendingTrialText = nil;
    if (!keepSelection) _pendingText = nil;
    _warmUpWhenAvailable = NO;
    if (_engine) _engine->cancel();
    _model.stopLoading();
    const BOOL showCancellation = _busy && !cancellingTrial && !_pendingText;
    _activeRequestId = 0;
    [self setTranslationBusy:_pendingText != nil];
    [self updateStatus];
    if (showCancellation) [self showStatus:@"Translation cancelled" kind:BawanStatusInformation owner:StatusOwner::TranslationOutcome];
    if (cancellingActiveRequest) [self replyToDeferredTerminationAfterResultInSelectionTrial:cancellingTrial];
}

- (void)cancelTranslation { [self cancelTranslationKeepingPendingSelection:NO]; }

- (void)openTranslation:(id)sender {
    if ([self needsOnboarding]) {
        if (_model.canEnterTranslator()) {
            [self finishOnboarding];
            if (!_busy) [self warmUpEngine];
        } else {
            [self showOnboarding];
        }
        return;
    }
    [_translationPanel showForManualInput];
    [self warmUpEngine];
}

- (void)handleSelectionTrialText:(NSString *)text {
    if (![self canAcceptTranslation]) return;
    if (![_onboardingViewController isSelectionTrialText:text]) return;
    NSUInteger attempt = [_onboardingViewController beginSelectionTrial];
    if (attempt) [self translateText:text direction:bawan::Direction::Automatic trialAttempt:attempt];
}

- (void)handleSelectionText:(NSString *)text {
    if (![self canAcceptTranslation]) return;
    if (_selectionTrialAttempt) [self cancelTranslationKeepingPendingSelection:YES];
    [_onboardingViewController discardSelectionTrialResult];
    [_translationPanel showForSelection:text];
    const BOOL needsOnboarding = [self needsOnboarding];
    if (needsOnboarding || _model.setupNotStarted()) {
        if (needsOnboarding && ![self modelFailed]) [self queueTranslation:text direction:bawan::Direction::Automatic];
        [self showOnboarding];
        return;
    }
    [self translateText:text direction:bawan::Direction::Automatic];
}

- (void)toggleShortcut:(NSMenuItem *)sender {
    auto action = static_cast<bawan::ShortcutAction>(sender.tag);
    auto binding = [_shortcutPreferences bindingForAction:action];
    binding.enabled = !binding.enabled;
    NSString *error = nil;
    if (![_shortcutPreferences setBinding:binding forAction:action error:&error]) {
        [self openSettings:nil];
        [_settingsViewController showError:error ?: @"Unable to enable this shortcut."];
    }
    [self updateShortcutItem];
}

- (void)performModelAction:(id)sender {
    switch (_model.phase()) {
        case BawanModelSetupDownloading:
            [_modelStore pause];
            return;
        case BawanModelSetupPaused:
        case BawanModelSetupResumableFailure:
            _model.beginPreparing();
            [self updateStatus];
            [_modelStore resume];
            return;
        case BawanModelSetupPreparing:
        case BawanModelSetupReady:
            return;
        case BawanModelSetupNeedsDownload:
        case BawanModelSetupFailed:
            [self beginModelSetup];
            return;
    }
}

- (void)retryModel:(id)sender {
    [self cancelTranslation];
    ++_engineGeneration;
    _engine.reset();
    _model.beginPreparing();
    [self updateStatus];
    [_modelStore revalidate];
}

- (void)openLoginSettings:(id)sender { [SMAppService openSystemSettingsLoginItems]; }

- (void)setLoginEnabled:(BOOL)enable {
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    BOOL success = enable ? [service registerAndReturnError:&error] : [service unregisterAndReturnError:&error];
    if (!success) {
        [_settingsViewController setLoginStatus:service.status
            message:error.localizedDescription ?: @"Unable to change the launch-at-login setting." error:YES];
    } else {
        [_settingsViewController setLoginStatus:service.status message:nil error:NO];
    }
}

- (void)openSettings:(id)sender {
    if (_selectionTrialAttempt) [self cancelTranslationKeepingPendingSelection:YES];
    if (!_settingsViewController) {
        _settingsViewController = [[SettingsViewController alloc] initWithPreferences:_shortcutPreferences monitor:_shortcut];
        __weak AppDelegate *weakSelf = self;
        _settingsViewController.onLoginSettings = ^{ [weakSelf openLoginSettings:nil]; };
        _settingsViewController.onLoginChanged = ^(BOOL enabled) { [weakSelf setLoginEnabled:enabled]; };
        _settingsViewController.onCheckForUpdates = ^{ [weakSelf checkForUpdates:nil]; };
        _settingsViewController.onAutomaticUpdatesChanged = ^(BOOL enabled) {
            AppDelegate *owner = weakSelf;
            if (owner) owner->_updater.automaticallyChecksForUpdates = enabled;
        };
        _settingsViewController.onModelLicense = ^{ [weakSelf showModelLicense:weakSelf]; };
        _settingsViewController.onModelSetup = ^{ [weakSelf performModelAction:nil]; };
    }
    [self refreshSettings];
    [_translationPanel showSettings:_settingsViewController];
    if ([self needsOnboarding]) {
        __weak AppDelegate *weakSelf = self;
        _settingsViewController.onBack = ^{ [weakSelf showOnboarding]; };
    }
}

- (void)refreshSettings {
    [_shortcut refresh];
    [self updateShortcutItem];
    [_settingsViewController setLoginStatus:SMAppService.mainAppService.status message:nil error:NO];
    [self pushModelStateToPage:_settingsViewController];
    [self refreshUpdateControls];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    if (_translationPanel.window.visible && _translationPanel.currentPage == BawanPanelPageSettings) {
        [self refreshSettings];
    } else {
        [_shortcut refresh];
    }
    [_onboardingViewController refresh];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [self openTranslation:nil];
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (!_updater.installingUpdate || _activeRequestId == 0) return NSTerminateNow;
    if (!_terminationReplyPending) {
        _terminationReplyPending = YES;
        _terminationReplyCancelled = NO;
        ++_terminationReplyGeneration;
    }
    return NSTerminateLater;
}

- (void)replyToDeferredTerminationAfterResultInSelectionTrial:(BOOL)selectionTrial {
    if (!_terminationReplyPending || _terminationReplyCancelled) return;
    NSWindow *window = _translationPanel.window;
    if (selectionTrial) {
        NSView *resultView = _onboardingViewController.view;
        [resultView layoutSubtreeIfNeeded];
        window = resultView.window;
    }
    if (!window) window = _translationPanel.window;
    [window.contentView layoutSubtreeIfNeeded];
    [window displayIfNeeded];
    [self enqueueTerminationReply:YES];
}

- (void)cancelDeferredTermination {
    if (!_terminationReplyPending) return;
    _terminationReplyCancelled = YES;
    ++_terminationReplyGeneration;
    [self enqueueTerminationReply:NO];
}

- (void)enqueueTerminationReply:(BOOL)shouldTerminate {
    if (!_terminationReplyPending || (shouldTerminate && _terminationReplyCancelled)) return;
    const uint64_t generation = _terminationReplyGeneration;
    __weak AppDelegate *weakSelf = self;
    PerformInCommonAndModalRunLoopModes(^{
        AppDelegate *owner = weakSelf;
        if (!owner || !owner->_terminationReplyPending ||
            owner->_terminationReplyGeneration != generation ||
            (shouldTerminate && owner->_terminationReplyCancelled)) return;
        owner->_terminationReplyPending = NO;
        owner->_terminationReplyCancelled = NO;
        [owner sendTerminationReply:shouldTerminate];
    });
}

- (void)sendTerminationReply:(BOOL)shouldTerminate {
    [NSApp replyToApplicationShouldTerminate:shouldTerminate];
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }

- (void)releaseEngineMemory {
    if (_engine) _engine->releaseMemory();
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    _terminating = YES;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_shortcut stop];
    [_modelStore cancel];
    if (_memoryPressure) {
        dispatch_source_cancel(_memoryPressure);
        _memoryPressure = nil;
    }
    if (_engine) {
        _engine->shutdown();
        _engine.reset();
    }
    [NSStatusBar.systemStatusBar removeStatusItem:_statusItem];
}
@end
