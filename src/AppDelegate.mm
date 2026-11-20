#import "AppDelegate.h"
#import "EngineHost.h"
#import "ModelStore.h"
#import "ModelSetupState.h"
#import "ShortcutMonitor.h"
#import "TranslationPanel.h"
#import "SettingsViewController.h"
#import "OnboardingViewController.h"
#import <ServiceManagement/ServiceManagement.h>

#include "TranslationSession.h"

#include <optional>
#include <utility>

enum class StatusOwner { None, ModelStatus, TranslationOutcome, ShortcutWarning };
using Session = bawan::TranslationSession;

@interface AppDelegate () <NSMenuDelegate> {
    NSStatusItem *_statusItem;
    NSMenuItem *_modelItem;
    NSMenuItem *_shortcutItem;
    NSMenuItem *_panelShortcutItem;
    NSMenuItem *_retryItem;
    SettingsViewController *_settingsViewController;
    OnboardingViewController *_onboardingViewController;
    NSUserDefaults *_defaults;
    ShortcutPreferences *_shortcutPreferences;
    TranslationPanel *_translationPanel;
    ModelStore *_modelStore;
    ShortcutMonitor *_shortcut;
    dispatch_source_t _memoryPressure;
    EngineHost *_engineHost;
    Session _translationSession;
    BOOL _terminating;
    StatusOwner _statusOwner;
    BawanModelState _model;
    NSString *_memoryProbeDirectory;
}
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults memoryProbeDirectory:(NSString *)probeDirectory;
- (Session &)translationSession;
- (void)applyTranslationEvent:(Session::Event)event;
- (void)applyTranslationEffects:(Session::Effects)effects wasBusy:(BOOL)wasBusy;
- (void)synchronizeTranslationModel;
- (void)invalidateSelectionTrial;
- (void)handleEngineLifecycle:(const bawan::engine::Lifecycle &)state;
@end

static NSString *const BawanOnboardingCompletedKey = @"firstLaunchShown";
static NSString *const BawanModelLicenseAcceptedKey = @"modelLicenseNoticeShown20261109";

@implementation AppDelegate

- (instancetype)init {
    return [self initWithDefaults:NSUserDefaults.standardUserDefaults
            memoryProbeDirectory:NSProcessInfo.processInfo.environment[@"BAWAN_MEMORY_PROBE"]];
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults memoryProbeDirectory:(NSString *)probeDirectory {
    self = [super init];
    if (self) {
        _defaults = defaults;
        _memoryProbeDirectory = [probeDirectory copy];
        _translationSession = Session{_memoryProbeDirectory.length || [_defaults boolForKey:BawanOnboardingCompletedKey]
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
    [self buildMenus];
    _translationPanel = [[TranslationPanel alloc] init];
    __weak AppDelegate *weakSelf = self;
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
    if (_memoryProbeDirectory.length) {
        [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(memoryProbeTick:)
                                      userInfo:nil repeats:YES];
    } else {
        [self startInitialSetup];
    }
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
    [_engineHost startWithModelURL:fileURL];
    _model.fileReady(fileURL);
    [self updateStatus];
    [self synchronizeTranslationModel];
}

- (void)modelFileDidFail:(NSString *)message {
    [_engineHost stopAndDiscardEvents];
    _model.fileFailed(message, _modelStore.canResume);
    [self synchronizeTranslationModel];
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
    }
    _onboardingViewController.onSelectionTrialInterrupted = ^{ [weakSelf invalidateSelectionTrial]; };
    [self pushModelStateToPage:_onboardingViewController];
    [_translationPanel showOnboarding:_onboardingViewController onBack:^{ [weakSelf finishOrCloseOnboarding]; }];
}

// The shortcut step's button: leave for the translator even while the model is
// still downloading. The translator shows preparation and translates once ready.
- (void)finishOnboardingFromShortcuts {
    if (!_model.canFinishSetup()) return;
    [self enterTranslatorFromOnboarding];
    if (![self busy]) [self warmUpEngine];
}

- (void)enterTranslatorFromOnboarding {
    [_onboardingViewController refresh];
    const BOOL wasOnboarding = [self needsOnboarding];
    const BOOL useTrial = _onboardingViewController.selectionTrialComplete;
    [self applyTranslationEvent:Session::OpenTranslator{
        useTrial ? Session::PendingSelection::Discard : Session::PendingSelection::Resume}];
    if (wasOnboarding) [_defaults setBool:YES forKey:BawanOnboardingCompletedKey];
    if (useTrial) {
        NSString *text = _onboardingViewController.selectionTrialText;
        NSString *output = _onboardingViewController.selectionTrialOutput;
        const auto direction = _onboardingViewController.selectionTrialDirection;
        [_translationPanel showForSelection:text];
        [_translationPanel setOutput:output direction:direction];
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
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self menuItem:@"Quit Bawan" action:@selector(quit:) key:@"q"]];
    _statusItem.menu = menu;

    // Native editing commands are required when the nonactivating panel becomes key.
    NSMenu *main = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"Bawan" action:NULL keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Bawan"];
    [appMenu addItem:[self menuItem:@"Settings…" action:@selector(openSettings:) key:@","]];
    [appMenu addItem:[self menuItem:@"Model License…" action:@selector(showModelLicense:) key:@""]];
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
    [self applyTranslationEffects:_translationSession.reduce(std::move(event), [self modelAvailability])
                         wasBusy:wasBusy];
}

- (void)synchronizeTranslationModel {
    if (_terminating) return;
    const BOOL wasBusy = [self busy];
    [self applyTranslationEffects:_translationSession.synchronizeModel([self modelAvailability])
                         wasBusy:wasBusy];
}

- (void)applyTranslationEffects:(Session::Effects)effects wasBusy:(BOOL)wasBusy {
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
                    if (_model.engine() == BawanModelState::Engine::Loading) {
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
                    [_translationPanel setOutput:StringFromUTF8(output.text) direction:output.direction];
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
                    [_onboardingViewController finishSelectionTrialWithOutput:output
                        direction:trial.output ? trial.output->direction : bawan::Direction::Automatic];
                },
                [&](Session::TrialDiscarded) {
                    [_onboardingViewController cancelSelectionTrial];
                },
            }, effect);
        }
        effects = std::move(next);
    }
    if (wasBusy != [self busy]) [_translationPanel setAvailable:[self hasVerifiedModelFile] busy:[self busy]];
}

- (void)handleEngineEvent:(const bawan::EngineEvent &)event {
    using namespace bawan::engine;
    const auto metadata = describe(event);
    if (_memoryProbeDirectory.length && metadata.probeValue) {
        [self memoryProbeWrite:@(metadata.probeValue) name:@"engine"];
    }
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
    if ([_onboardingViewController beginSelectionTrialForText:text]) {
        [self submitText:text direction:bawan::Direction::Automatic origin:Session::Trial{}];
    }
}

- (void)handleSelectionText:(NSString *)text {
    [_onboardingViewController clearSelectionCopyError];
    [_onboardingViewController discardSelectionTrialResult];
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
    [_engineHost stopAndDiscardEvents];
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
    if (!_settingsViewController) {
        _settingsViewController = [[SettingsViewController alloc] initWithPreferences:_shortcutPreferences monitor:_shortcut];
        __weak AppDelegate *weakSelf = self;
        _settingsViewController.onLoginSettings = ^{ [weakSelf openLoginSettings:nil]; };
        _settingsViewController.onLoginChanged = ^(BOOL enabled) { [weakSelf setLoginEnabled:enabled]; };
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

- (void)quit:(id)sender { [NSApp terminate:nil]; }

- (void)releaseEngineMemory {
    [_engineHost releaseMemory];
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
    [_engineHost stopAndDiscardEvents];
    [NSStatusBar.systemStatusBar removeStatusItem:_statusItem];
}
@end
