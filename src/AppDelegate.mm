#import "AppDelegate.h"
#import "EngineHost.h"
#import "MemoryProbe.h"
#import "ModelStore.h"
#import "ModelSetupState.h"
#import "ShortcutMonitor.h"
#import "TranslationPanel.h"
#import "SettingsViewController.h"
#import "AppUpdater.h"
#import "ApplicationRunLoop.h"
#import "OnboardingViewController.h"
#import <ServiceManagement/ServiceManagement.h>

#include "TranslationSession.h"

#include <optional>
#include <utility>

enum class StatusOwner { None, ModelStatus, TranslationOutcome, ShortcutWarning };
using Session = bawan::TranslationSession;

struct CompletedPractice {
    NSString *source;
    NSString *output;
    bawan::Direction direction;
    bawan::ShortcutBinding binding;
};

@interface AppDelegate () <NSMenuDelegate> {
    NSStatusItem *_statusItem;
    NSMenuItem *_modelItem;
    NSMenuItem *_shortcutItem;
    NSMenuItem *_panelShortcutItem;
    NSMenuItem *_retryItem;
    NSMenuItem *_checkUpdatesItem;
    NSMenuItem *_mainCheckUpdatesItem;
    AppUpdater *_updater;
    NSAlert *_updateResultAlert;
    __weak SettingsViewController *_settingsViewController;
    __weak OnboardingViewController *_onboardingViewController;
    NSUserDefaults *_defaults;
    ShortcutPreferences *_shortcutPreferences;
    TranslationPanel *_translationPanel;
    ModelStore *_modelStore;
    ShortcutMonitor *_shortcut;
    dispatch_source_t _memoryPressure;
    EngineHost *_engineHost;
    Session _translationSession;
    std::optional<CompletedPractice> _completedPractice;
    BOOL _terminating;
    BOOL _terminationReplyPending;
    BOOL _terminationReplyCancelled;
    uint64_t _terminationReplyGeneration;
    StatusOwner _statusOwner;
    BawanModelState _model;
    MemoryProbe *_memoryProbe;
    bawan::LaunchMode _launchMode;
}
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults launchMode:(bawan::LaunchMode)mode;
- (Session &)translationSession;
- (void)applyTranslationEvent:(Session::Event)event;
- (void)applyTranslationEffects:(Session::Effects)effects wasBusy:(BOOL)wasBusy wasRunning:(BOOL)wasRunning;
- (void)synchronizeTranslationModel;
- (void)invalidateSelectionTrial;
- (void)handleEngineLifecycle:(const bawan::engine::Lifecycle &)state;
- (void)refreshUpdateControls;
- (void)updaterStateDidChange;
- (BOOL)canAcceptTranslation;
- (void)offerUpdateResult:(NSString *)result;
- (void)cancelDeferredTermination;
- (void)enqueueTerminationReply:(BOOL)shouldTerminate;
- (void)sendTerminationReply:(BOOL)shouldTerminate;
@end

static NSString *const BawanOnboardingCompletedKey = @"firstLaunchShown";
static NSString *const BawanModelLicenseAcceptedKey = @"modelLicenseNoticeShown20261109";

@implementation AppDelegate

- (instancetype)init {
    return [self initWithLaunchMode:bawan::InteractiveLaunch{}];
}

- (instancetype)initWithLaunchMode:(bawan::LaunchMode)mode {
    return [self initWithDefaults:NSUserDefaults.standardUserDefaults launchMode:std::move(mode)];
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults launchMode:(bawan::LaunchMode)mode {
    self = [super init];
    if (self) {
        _defaults = defaults;
        _launchMode = std::move(mode);
        _translationSession = Session{std::holds_alternative<bawan::MemoryProbeLaunch>(_launchMode) ||
            [_defaults boolForKey:BawanOnboardingCompletedKey]
            ? Session::TranslatorAccess::Open : Session::TranslatorAccess::AwaitingOnboarding};
        __weak AppDelegate *weakSelf = self;
        _engineHost = [[EngineHost alloc] initWithEventHandler:^(const bawan::EngineEvent &event) {
            AppDelegate *owner = weakSelf;
            if (owner && !owner->_terminating) [owner handleEngineEvent:event];
        }];
    }
    return self;
}

- (BOOL)hasVerifiedModelFile { return _model.hasVerifiedFile(); }
- (BOOL)modelFailed { return _model.failed(); }
- (NSURL *)modelURL { return _model.url(); }
- (NSString *)modelStatus { return _model.message(); }

- (Session &)translationSession { return _translationSession; }

- (BOOL)busy { return _translationSession.busy(); }

- (Session::ModelAvailability)modelAvailability {
    if (_model.hasVerifiedFile()) return Session::ModelAvailability::Available;
    return _model.failed() ? Session::ModelAvailability::Failed : Session::ModelAvailability::Pending;
}

static NSString *StringFromUTF8(const std::string &text) {
    return [[NSString alloc] initWithBytes:text.data() length:text.size()
                                 encoding:NSUTF8StringEncoding] ?: @"Unable to display the text.";
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _shortcutPreferences = [[ShortcutPreferences alloc] init];
    _updater = [[AppUpdater alloc] init];
    [self buildMenus];
    [self connectTranslationPanel:[[TranslationPanel alloc] init]];
    __weak AppDelegate *weakSelf = self;
    _updater.onStateChanged = ^{ [weakSelf updaterStateDidChange]; };

    _memoryPressure = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, dispatch_get_main_queue());
    dispatch_source_set_event_handler(_memoryPressure, ^{ [weakSelf releaseEngineMemory]; });
    dispatch_resume(_memoryPressure);

    [self connectModelStore:[[ModelStore alloc] init]];

    _shortcut = [[ShortcutMonitor alloc] initWithPreferences:_shortcutPreferences];
    _shortcut.onSelection = ^(const SelectionEvent &event) {
        AppDelegate *owner = weakSelf;
        if (!owner || owner->_terminating) return;
        std::visit([&](const auto &value) {
            using Value = std::decay_t<decltype(value)>;
            if constexpr (std::is_same_v<Value, SelectedText>) [owner handleSelectionText:value.text];
            else if constexpr (std::is_same_v<Value, SelectionTrial>) [owner handleSelectionTrialText:value.text];
            else [owner handleShortcutProblem:value.message];
        }, event);
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
    if (const auto *probe = std::get_if<bawan::MemoryProbeLaunch>(&_launchMode)) {
        _memoryProbe = [[MemoryProbe alloc] initWithDirectory:probe->directory commands:@{
            @"ping": ^NSString *{ return @"ok"; },
            @"translation": ^NSString *{
                AppDelegate *owner = weakSelf;
                if (owner) [owner->_translationPanel showForManualInput];
                return @"ok";
            },
            @"close": ^NSString *{
                AppDelegate *owner = weakSelf;
                if (owner) [owner->_translationPanel close];
                return @"ok";
            },
            @"settings": ^NSString *{ [weakSelf openSettings:nil]; return @"ok"; },
            @"setup": ^NSString *{ [weakSelf showOnboarding]; return @"ok"; },
            @"prepare": ^NSString *{ [weakSelf prepareModel]; return @"ok"; },
            @"translate": ^NSString *{
                [weakSelf translateText:@"Hello. How are you?" direction:bawan::Direction::EnglishToJapanese];
                return @"ok";
            },
            @"model": ^NSString *{
                return [weakSelf hasVerifiedModelFile] ? @"ready" : ([weakSelf modelFailed] ? @"error" : @"waiting");
            }
        }];
        [_memoryProbe start];
    } else {
        [self startInitialSetup];
    }
    [_updater start];
}

- (void)modelStoreDidChange:(const ModelStoreSnapshot &)snapshot {
    _model.fileChanged(snapshot);
    if (const auto *ready = std::get_if<ModelReady>(&snapshot)) {
        [_engineHost startWithModelURL:ready->url];
        [self updateStatus];
        [self synchronizeTranslationModel];
        return;
    }
    if (std::holds_alternative<ModelFailed>(snapshot)) {
        [_engineHost stopAndDiscardEvents];
        [self synchronizeTranslationModel];
    }
    [self updateStatus];
}

- (BOOL)needsOnboarding { return _translationSession.access() == Session::TranslatorAccess::AwaitingOnboarding; }

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
    [_modelStore prepare];
}

- (void)discardUnavailablePractice {
    if (!_completedPractice) return;
    constexpr auto action = bawan::ShortcutAction::TranslateSelection;
    if (!_model.canFinishSetup() || _completedPractice->binding != [_shortcutPreferences bindingForAction:action] ||
        [_shortcut availabilityForAction:action] != ShortcutAvailabilityAvailable) {
        _completedPractice.reset();
    }
}

- (void)showOnboarding {
    __weak AppDelegate *weakSelf = self;
    OnboardingViewController *onboarding = _onboardingViewController;
    const BOOL created = onboarding == nil;
    if (created) {
        onboarding = [[OnboardingViewController alloc] initWithPreferences:_shortcutPreferences monitor:_shortcut];
        onboarding.onModelSetup = ^{ [weakSelf performModelAction:nil]; };
        onboarding.onModelLicense = ^{ [weakSelf showModelLicense:weakSelf]; };
        onboarding.onFinish = ^{ [weakSelf finishOnboardingFromShortcuts]; };
        onboarding.onSelectionTrialDiscarded = ^{
            AppDelegate *owner = weakSelf;
            if (owner) owner->_completedPractice.reset();
        };
        _onboardingViewController = onboarding;
    }
    onboarding.onSelectionTrialInterrupted = ^{ [weakSelf invalidateSelectionTrial]; };
    [self discardUnavailablePractice];
    [_translationPanel showOnboarding:onboarding onBack:^{ [weakSelf finishOrCloseOnboarding]; }];
    if (created && _completedPractice) [onboarding restoreCompletedSelectionTrial];
}

// The shortcut step's button: leave for the translator even while the model is
// still downloading. The translator shows preparation and translates once ready.
- (void)finishOnboardingFromShortcuts {
    if (!_model.canFinishSetup()) return;
    [self enterTranslatorFromOnboarding];
    if (![self busy]) [self warmUpEngine];
}

- (void)enterTranslatorFromOnboarding {
    if (![self canAcceptTranslation]) return;
    [_onboardingViewController refresh];
    [self discardUnavailablePractice];
    const auto practice = std::exchange(_completedPractice, std::nullopt);
    const BOOL wasOnboarding = [self needsOnboarding];
    [self applyTranslationEvent:Session::OpenTranslator{
        practice ? Session::PendingSelection::Discard : Session::PendingSelection::Resume}];
    if (wasOnboarding) [_defaults setBool:YES forKey:BawanOnboardingCompletedKey];
    if (practice) {
        [_translationPanel showForSelection:practice->source];
        [_translationPanel setOutput:practice->output direction:practice->direction];
    }
    [_translationPanel showForManualInput];
}

- (void)finishOrCloseOnboarding {
    if (!_model.canEnterTranslator()) {
        [_translationPanel close];
        return;
    }
    [self enterTranslatorFromOnboarding];
}

- (void)connectTranslationPanel:(TranslationPanel *)panel {
    _translationPanel = panel;
    __weak AppDelegate *weakSelf = self;
    panel.onTranslate = ^(NSString *text, bawan::Direction direction) {
        [weakSelf translateText:text direction:direction];
    };
    panel.onCancel = ^{ [weakSelf cancelTranslation]; };
    panel.onClose = ^{ [weakSelf cancelTranslation]; };
    panel.onSettings = ^{ [weakSelf openSettings:nil]; };
    [self showModelSetupOnPanel];
}

- (void)connectModelStore:(ModelStore *)store {
    _modelStore = store;
    __weak AppDelegate *weakSelf = self;
    store.onChange = ^(const ModelStoreSnapshot &snapshot) {
        AppDelegate *owner = weakSelf;
        if (owner && !owner->_terminating) [owner modelStoreDidChange:snapshot];
    };
}

- (void)showModelSetupOnPanel {
    const BawanModelSetupView view = _model.view();
    [_translationPanel setModelPhase:view.phase message:view.message progress:view.progress];
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
    if (_updater.installingUpdate || _updater.relaunchPostponed) return;
    [self cancelDeferredTermination];
    NSAlert *alert = _updateResultAlert;
    if (alert) {
        _updateResultAlert = nil;
        if (NSApp.modalWindow == alert.window) [NSApp abortModal];
        _updater.translationBusy = [self busy];
    }
    if (_translationSession.phase() == Session::Phase::Queued) [self synchronizeTranslationModel];
}

- (void)checkForUpdates:(id)sender { [_updater checkForUpdates:sender]; }

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    return item.action != @selector(checkForUpdates:) || _updater.canCheckForUpdates;
}

- (BOOL)canAcceptTranslation {
    return !_terminating && !_updater.installingUpdate && !_updater.relaunchPostponed;
}

- (void)updateStatus {
    [self showModelSetupOnPanel];
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
            [_translationPanel setAvailable:available busy:[self busy]];
            break;
    }
}

- (void)showStatus:(NSString *)message kind:(BawanStatusKind)kind owner:(StatusOwner)owner {
    _statusOwner = message.length ? owner : StatusOwner::None;
    [_translationPanel setAvailable:[self hasVerifiedModelFile] busy:[self busy] status:message kind:kind];
}

- (void)handleShortcutProblem:(NSString *)message {
    [self updateShortcutItem];
    if ([self needsOnboarding]) {
        [self showOnboarding];
        [_onboardingViewController showSelectionCopyError:message];
    } else {
        [_translationPanel showWithoutChangingInput];
        [self showStatus:message kind:BawanStatusWarning owner:StatusOwner::ShortcutWarning];
    }
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
    [_settingsViewController refresh];
    [_onboardingViewController refresh];
}

- (void)shortcutPreferencesDidChange:(NSNotification *)notification { [self updateShortcutItem]; }

- (void)menuWillOpen:(NSMenu *)menu {
    [_shortcut refresh];
    [self updateShortcutItem];
}

- (void)warmUpEngine {
    [self applyTranslationEvent:Session::WarmUpRequested{}];
}

- (void)submitText:(NSString *)text direction:(bawan::Direction)direction origin:(Session::Origin)origin {
    if (![self canAcceptTranslation]) return;
    if (const char *utf8 = text.UTF8String) {
        std::string source(utf8, [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
        [self applyTranslationEvent:Session::Submit{{std::move(source), direction}, std::move(origin)}];
    }
}

- (void)translateText:(NSString *)text direction:(bawan::Direction)direction {
    [self submitText:text direction:direction origin:Session::Manual{}];
}

- (void)applyTranslationEvent:(Session::Event)event {
    if (_terminating) return;
    const BOOL wasBusy = [self busy];
    const BOOL wasRunning = _translationSession.activeRequestId().has_value();
    [self applyTranslationEffects:_translationSession.reduce(std::move(event), [self modelAvailability])
                         wasBusy:wasBusy wasRunning:wasRunning];
}

- (void)synchronizeTranslationModel {
    if (_terminating) return;
    const BOOL wasBusy = [self busy];
    const BOOL wasRunning = _translationSession.activeRequestId().has_value();
    const auto availability = [self modelAvailability];
    if (availability == Session::ModelAvailability::Available && ![self canAcceptTranslation]) return;
    [self applyTranslationEffects:_translationSession.synchronizeModel(availability)
                         wasBusy:wasBusy wasRunning:wasRunning];
}

- (void)applyTranslationEffects:(Session::Effects)effects wasBusy:(BOOL)wasBusy wasRunning:(BOOL)wasRunning {
    NSString *result = nil;
    while (!effects.empty()) {
        Session::Effects next;
        for (auto &effect : effects) {
            std::visit(bawan::engine::Visitor{
                [&](Session::SubmitRequest &request) {
                    const auto id = [_engineHost translate:std::move(request.source.text)
                                                direction:request.source.direction];
                    next = _translationSession.resolveSubmission(id);
                },
                [&](Session::CancelEngine) {
                    [_engineHost cancel];
                    if (const auto *ready = std::get_if<BawanModelReady>(&_model.setup());
                        ready && std::holds_alternative<BawanEngineLoading>(ready->engine)) {
                        _model.stopLoading();
                        [self updateStatus];
                    }
                },
                [&](Session::WarmUp) {
                    [_engineHost warmUp];
                },
                [&](Session::ClearOutput) {
                    [_translationPanel setOutput:@"" direction:bawan::Direction::Automatic];
                },
                [&](const Session::Output &output) {
                    result = StringFromUTF8(output.text);
                    [_translationPanel setOutput:result direction:output.direction];
                },
                [&](Session::Status outcome) {
                    switch (outcome) {
                        case Session::Status::Clear:
                            [self showStatus:@"" kind:BawanStatusInformation owner:StatusOwner::TranslationOutcome];
                            break;
                        case Session::Status::Cancelled:
                            [self showStatus:@"Translation cancelled" kind:BawanStatusInformation
                                       owner:StatusOwner::TranslationOutcome];
                            break;
                        case Session::Status::Truncated:
                            [self showStatus:@"Output limit reached. The translation is incomplete. Select less text and try again."
                                        kind:BawanStatusWarning owner:StatusOwner::TranslationOutcome];
                            break;
                    }
                },
                [&](const Session::TranslationError &error) {
                    [self showStatus:StringFromUTF8(error.message) kind:BawanStatusError
                               owner:StatusOwner::TranslationOutcome];
                },
                [&](const Session::TrialFinished &trial) {
                    NSString *output = trial.output ? [[NSString alloc] initWithBytes:trial.output->text.data()
                        length:trial.output->text.size() encoding:NSUTF8StringEncoding] : nil;
                    OnboardingViewController *onboarding = _onboardingViewController;
                    if ([onboarding finishSelectionTrialWithOutput:output]) {
                        result = output;
                        _completedPractice = CompletedPractice{
                            [onboarding.selectionTrialText copy], output, trial.output->direction,
                            [_shortcutPreferences bindingForAction:bawan::ShortcutAction::TranslateSelection]};
                    }
                },
                [&](Session::TrialDiscarded) {
                    [_onboardingViewController cancelSelectionTrial];
                },
            }, effect);
        }
        effects = std::move(next);
    }
    if (wasBusy != [self busy]) [_translationPanel setAvailable:[self hasVerifiedModelFile] busy:[self busy]];
    const BOOL running = _translationSession.activeRequestId().has_value();
    _updater.translationActive = running;
    if (wasRunning && !running) [self offerUpdateResult:result];
    if (_updater && !_updateResultAlert && _updater.translationBusy != [self busy]) {
        _updater.translationBusy = [self busy];
    }
}

- (void)handleEngineEvent:(const bawan::EngineEvent &)event {
    [_memoryProbe recordEngineEvent:event];
    if (const auto *state = std::get_if<bawan::engine::Lifecycle>(&event)) {
        [self handleEngineLifecycle:*state];
        return;
    }
    [self applyTranslationEvent:event];
}

- (void)handleEngineLifecycle:(const bawan::engine::Lifecycle &)state {
    using namespace bawan::engine;
    std::visit(Visitor{
        [self](Loading) { _model.engineLoading(); [self updateStatus]; },
        [self](Ready) { _model.engineIdle(); [self updateStatus]; },
        [](Idle) {},
        [self](LoadCancelled) { _model.engineIdle(); [self updateStatus]; },
        [self](const Failed &failure) { _model.engineFailed(StringFromUTF8(failure.message)); [self updateStatus]; },
    }, state);
}

- (void)invalidateSelectionTrial {
    [self applyTranslationEvent:Session::TrialInvalidated{}];
}

- (void)cancelTranslation {
    [self applyTranslationEvent:Session::Cancel{}];
}

- (void)openTranslation:(id)sender {
    if ([self needsOnboarding]) {
        if (_model.canEnterTranslator()) {
            [self enterTranslatorFromOnboarding];
            if (![self busy]) [self warmUpEngine];
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
    if ([_onboardingViewController beginSelectionTrialForText:text]) {
        [self submitText:text direction:bawan::Direction::Automatic origin:Session::Trial{}];
    }
}

- (void)handleSelectionText:(NSString *)text {
    if (![self canAcceptTranslation]) return;
    [_onboardingViewController clearSelectionCopyError];
    [_onboardingViewController discardSelectionTrialResult];
    _completedPractice.reset();
    const BOOL needsOnboarding = [self needsOnboarding];
    if (needsOnboarding || _model.setupNotStarted()) {
        [_translationPanel setSelection:text];
        if (needsOnboarding) [self submitText:text direction:bawan::Direction::Automatic origin:Session::Selection{}];
        [self showOnboarding];
        return;
    }
    [_translationPanel showForSelection:text];
    [self submitText:text direction:bawan::Direction::Automatic origin:Session::Selection{}];
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
    [_engineHost stopAndDiscardEvents];
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
    __weak AppDelegate *weakSelf = self;
    SettingsViewController *settings = _settingsViewController;
    if (!settings) {
        settings = [[SettingsViewController alloc] initWithPreferences:_shortcutPreferences monitor:_shortcut];
        settings.onLoginSettings = ^{ [weakSelf openLoginSettings:nil]; };
        settings.onLoginChanged = ^(BOOL enabled) { [weakSelf setLoginEnabled:enabled]; };
        settings.onCheckForUpdates = ^{ [weakSelf checkForUpdates:nil]; };
        settings.onAutomaticUpdatesChanged = ^(BOOL enabled) {
            AppDelegate *owner = weakSelf;
            if (owner) owner->_updater.automaticallyChecksForUpdates = enabled;
        };
        settings.onModelLicense = ^{ [weakSelf showModelLicense:weakSelf]; };
        settings.onModelSetup = ^{ [weakSelf performModelAction:nil]; };
        _settingsViewController = settings;
    }
    [self refreshSettings];
    [_translationPanel showSettings:settings];
}

- (void)refreshSettings {
    [_shortcut refresh];
    [self updateShortcutItem];
    [_settingsViewController setLoginStatus:SMAppService.mainAppService.status message:nil error:NO];
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
    if (!_terminationReplyPending &&
        (!_updater.installingUpdate || (!_translationSession.activeRequestId() && !_updateResultAlert))) {
        return NSTerminateNow;
    }
    if (!_terminationReplyPending) {
        _terminationReplyPending = YES;
        _terminationReplyCancelled = NO;
        ++_terminationReplyGeneration;
    }
    return NSTerminateLater;
}

- (NSModalResponse)presentUpdateResultAlert:(NSAlert *)alert {
    [NSApp activateIgnoringOtherApps:YES];
    return [alert runModal];
}

- (BOOL)copyUpdateResult:(NSString *)result {
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    return [pasteboard setString:result forType:NSPasteboardTypeString];
}

- (void)offerUpdateResult:(NSString *)result {
    if (_updateResultAlert || _terminationReplyCancelled ||
        (!_updater.installingUpdate && !_updater.relaunchPostponed)) return;
    NSWindow *window = _translationPanel.window;
    [window.contentView layoutSubtreeIfNeeded];
    [window displayIfNeeded];
    if (!result.length) {
        [self enqueueTerminationReply:YES];
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Translation ready";
    alert.informativeText = @"Bawan is ready to install the update. Copy your translation to keep it after restarting.";
    [alert addButtonWithTitle:@"Copy and Restart"];
    [alert addButtonWithTitle:@"Restart"];
    _updateResultAlert = alert;

    __weak AppDelegate *weakSelf = self;
    PerformInApplicationRunLoop(^{
        AppDelegate *owner = weakSelf;
        while (owner && owner->_updateResultAlert == alert) {
            const NSModalResponse choice = [owner presentUpdateResultAlert:alert];
            if (owner->_updateResultAlert != alert) return;
            if (choice == NSAlertFirstButtonReturn && ![owner copyUpdateResult:result]) {
                alert.informativeText = @"Bawan couldn't copy the translation. Try again, or choose Restart.";
                continue;
            }
            if (choice != NSAlertFirstButtonReturn && choice != NSAlertSecondButtonReturn) continue;
            owner->_updateResultAlert = nil;
            owner->_updater.translationBusy = [owner busy];
            [owner enqueueTerminationReply:YES];
        }
    });
}

- (void)cancelDeferredTermination {
    if (!_terminationReplyPending || _terminationReplyCancelled) return;
    _terminationReplyCancelled = YES;
    ++_terminationReplyGeneration;
    [self enqueueTerminationReply:NO];
}

- (void)enqueueTerminationReply:(BOOL)shouldTerminate {
    if (!_terminationReplyPending || (shouldTerminate && _terminationReplyCancelled)) return;
    const uint64_t generation = _terminationReplyGeneration;
    __weak AppDelegate *weakSelf = self;
    PerformInApplicationRunLoop(^{
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
    [_engineHost releaseMemory];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    _terminating = YES;
    _memoryProbe = nil;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_shortcut stop];
    [_modelStore cancel];
    if (_memoryPressure) {
        dispatch_source_cancel(_memoryPressure);
        _memoryPressure = nil;
    }
    [_engineHost stopAndDiscardEvents];
    [NSStatusBar.systemStatusBar removeStatusItem:_statusItem];
}
@end
