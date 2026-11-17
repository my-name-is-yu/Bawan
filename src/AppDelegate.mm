#import "AppDelegate.h"
#import "ModelStore.h"
#import "ModelSetupState.h"
#import "ShortcutMonitor.h"
#import "TranslationPanel.h"
#import "SettingsViewController.h"
#import "OnboardingViewController.h"
#import <ServiceManagement/ServiceManagement.h>

#include "TranslationEngine.h"
#include "EngineEventMailbox.h"
#include <memory>

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
    std::unique_ptr<bawan::TranslationEngine> _engine;
    uint64_t _activeRequestId;
    uint64_t _engineGeneration;
    NSString *_pendingText;
    bawan::Direction _pendingDirection;
    NSUInteger _selectionTrialAttempt;
    BOOL _warmUpWhenAvailable;
    BOOL _busy;
    BOOL _terminating;
    BOOL _showingModelStatus;
    BawanModelState _model;
}
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
    _shortcut.onText = ^(NSString *text) {
        AppDelegate *owner = weakSelf;
        if (!owner || owner->_terminating) return;
        [owner handleSelectionText:text];
    };
    _shortcut.onProblem = ^(NSString *message) {
        AppDelegate *owner = weakSelf;
        if (!owner || owner->_terminating) return;
        [owner updateShortcutItem];
        [owner->_translationPanel showWithoutChangingInput];
        [owner showTranslationStatus:message kind:BawanStatusWarning];
        owner->_statusItem.button.toolTip = message;
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
    [self startInitialSetup];
}

- (void)modelFileDidProgress:(double)progress message:(NSString *)message {
    _model.fileProgress(progress, message);
    [self updateStatus];
}

- (void)modelFileDidBecomeReady:(NSURL *)fileURL {
    _model.fileReady(fileURL);
    if (_pendingText) {
        NSString *text = _pendingText;
        if (_selectionTrialAttempt && ![_onboardingViewController isSelectionTrialCurrent:_selectionTrialAttempt]) {
            [self cancelTranslation];
        } else {
            [self translateText:text direction:_pendingDirection trialAttempt:_selectionTrialAttempt];
        }
    } else if (_warmUpWhenAvailable) {
        [self warmUpEngine];
    }
    [self updateStatus];
}

- (void)modelFileDidFail:(NSString *)message {
    [_onboardingViewController cancelSelectionTrial];
    _selectionTrialAttempt = 0;
    _model.fileFailed(message);
    _pendingText = nil;
    _warmUpWhenAvailable = NO;
    _busy = NO;
    _activeRequestId = 0;
    [self updateStatus];
}

- (BOOL)needsOnboarding { return ![_defaults boolForKey:BawanOnboardingCompletedKey]; }

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
    if (!_onboardingViewController) {
        _onboardingViewController = [[OnboardingViewController alloc]
            initWithPreferences:_shortcutPreferences monitor:_shortcut];
        __weak AppDelegate *weakSelf = self;
        _onboardingViewController.onModelSetup = ^{ [weakSelf beginModelSetup]; };
        _onboardingViewController.onModelLicense = ^{ [weakSelf showModelLicense:weakSelf]; };
        _onboardingViewController.onFinish = ^{ [weakSelf finishOnboardingFromShortcuts]; };
    }
    [self pushModelStateToPage:_onboardingViewController];
    __weak AppDelegate *weakSelf = self;
    [_translationPanel showOnboarding:_onboardingViewController onBack:^{ [weakSelf finishOnboarding]; }];
}

// The shortcut step's button: leave for the translator even while the model is
// still downloading. The translator shows preparation and translates once ready.
- (void)finishOnboardingFromShortcuts {
    if (!_model.canFinishSetup()) return;
    [self enterTranslatorFromOnboarding];
    [self warmUpEngine];
}

- (void)enterTranslatorFromOnboarding {
    [_onboardingViewController refresh];
    if (_selectionTrialAttempt) [self cancelTranslation];
    [self markOnboardingComplete];
    if (_onboardingViewController.selectionTrialComplete) {
        NSString *text = _onboardingViewController.selectionTrialText;
        NSString *output = _onboardingViewController.selectionTrialOutput;
        const auto direction = _onboardingViewController.selectionTrialDirection;
        [_translationPanel showForSelection:text];
        [_translationPanel setOutput:output direction:direction];
    }
    [_translationPanel showForManualInput];
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
    if (_onboardingViewController.view.window) [self pushModelStateToPage:_onboardingViewController];
    if (_settingsViewController.view.window) [self pushModelStateToPage:_settingsViewController];
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
    _retryItem = [self menuItem:@"Retry Model Setup" action:@selector(retryModel:) key:@""];
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
    _retryItem.hidden = !failed;
    _retryItem.enabled = failed;
    _statusItem.button.toolTip = [@"Bawan — " stringByAppendingString:_modelItem.title];
    BOOL hasModelMessage = _model.phase() != BawanModelSetupReady;
    if (hasModelMessage || _showingModelStatus) {
        // Ready clears a preceding model message, including Loading while busy.
        // It must not erase a translation outcome or a shortcut warning.
        _showingModelStatus = hasModelMessage;
        [_translationPanel setAvailable:available busy:_busy status:hasModelMessage ? _modelItem.title : @""
                                  kind:failed ? BawanStatusError : BawanStatusInformation];
    } else {
        [_translationPanel setAvailable:available busy:_busy];
    }
}

- (void)showTranslationStatus:(NSString *)message kind:(BawanStatusKind)kind {
    _showingModelStatus = NO;
    [_translationPanel setAvailable:[self hasVerifiedModelFile] busy:_busy status:message kind:kind];
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
    const BOOL onboardingUpdatedByCancellation = cancelTrial && _onboardingViewController.view.window != nil;
    if (cancelTrial) [self cancelTranslation];
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
                dispatch_async(dispatch_get_main_queue(), ^{
                    AppDelegate *owner = weakSelf;
                    const auto events = mailbox->drain();
                    if (owner && !owner->_terminating && owner->_engineGeneration == generation) {
                        for (const auto &queued : events) [owner handleEngineEvent:queued];
                    }
                });
            }
        });
}

- (void)warmUpEngine {
    if (_terminating) return;
    _warmUpWhenAvailable = ![self hasVerifiedModelFile];
    [self ensureEngine];
    if (_engine) _engine->warmUp();
}

- (void)translateText:(NSString *)text direction:(bawan::Direction)direction {
    if (_selectionTrialAttempt) [self cancelTranslation];
    [self translateText:text direction:direction trialAttempt:0];
}

- (void)translateText:(NSString *)text direction:(bawan::Direction)direction trialAttempt:(NSUInteger)attempt {
    if (_terminating) return;
    _selectionTrialAttempt = attempt;
    if (![self hasVerifiedModelFile]) {
        if ([self modelFailed]) {
            [_onboardingViewController finishSelectionTrial:attempt output:nil direction:direction];
            _selectionTrialAttempt = 0;
            [self updateStatus];
            return;
        }
        _pendingText = [text copy];
        _pendingDirection = direction;
        _activeRequestId = 0;
        _busy = YES;
        [_translationPanel setOutput:@"" direction:bawan::Direction::Automatic];
        [self updateStatus];
        return;
    }
    if (!attempt) [self markOnboardingComplete];
    _pendingText = nil;
    _warmUpWhenAvailable = NO;
    [self ensureEngine];
    const char *utf8 = text.UTF8String;
    if (!utf8) return;
    _activeRequestId = _engine->translate(std::string(utf8, [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]), direction);
    _busy = YES;
    [_translationPanel setOutput:@"" direction:bawan::Direction::Automatic];
    [self showTranslationStatus:@"" kind:BawanStatusInformation];
}

- (void)handleEngineEvent:(const bawan::EngineEvent &)event {
    using Kind = bawan::EngineEvent::Kind;
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
            [self cancelTranslation];
            return;
        }
        if (event.kind == Kind::Complete || event.kind == Kind::Cancelled || event.kind == Kind::Error) {
            _busy = NO;
            _activeRequestId = 0;
            _selectionTrialAttempt = 0;
            NSString *output = event.kind == Kind::Complete && !event.truncated ?
                [[NSString alloc] initWithBytes:event.text.data() length:event.text.size()
                    encoding:NSUTF8StringEncoding] : nil;
            [_onboardingViewController finishSelectionTrial:attempt output:output direction:event.direction];
            [self updateStatus];
        }
        return;
    }
    switch (event.kind) {
        case Kind::Text:
            [_translationPanel setOutput:StringFromUTF8(event.text) direction:event.direction];
            break;
        case Kind::Complete:
            _busy = NO;
            _activeRequestId = 0;
            [_translationPanel setOutput:StringFromUTF8(event.text) direction:event.direction];
            [self showTranslationStatus:event.truncated ?
                @"Output limit reached. The translation is incomplete. Select less text and try again." : @""
                                      kind:event.truncated ? BawanStatusWarning : BawanStatusInformation];
            break;
        case Kind::Cancelled:
            _busy = NO;
            _activeRequestId = 0;
            [self showTranslationStatus:@"Translation cancelled" kind:BawanStatusInformation];
            break;
        case Kind::Error:
            _busy = NO;
            _activeRequestId = 0;
            [self showTranslationStatus:StringFromUTF8(event.text) kind:BawanStatusError];
            break;
        default: break;
    }
}

- (void)cancelTranslation {
    [_onboardingViewController cancelSelectionTrial];
    _selectionTrialAttempt = 0;
    _pendingText = nil;
    _warmUpWhenAvailable = NO;
    if (_engine) _engine->cancel();
    _model.stopLoading();
    if (!_busy) { [self updateStatus]; return; }
    _activeRequestId = 0;
    _busy = NO;
    [self updateStatus];
    [self showTranslationStatus:@"Translation cancelled" kind:BawanStatusInformation];
}

- (void)openTranslation:(id)sender {
    if ([self needsOnboarding]) {
        if (_model.canEnterTranslator()) {
            [self finishOnboarding];
            [self warmUpEngine];
        } else {
            [self showOnboarding];
        }
        return;
    }
    [_translationPanel showForManualInput];
    [self warmUpEngine];
}

- (void)handleSelectionText:(NSString *)text {
    if ([_onboardingViewController isSelectionTrialText:text]) {
        NSUInteger attempt = [_onboardingViewController beginSelectionTrial];
        if (attempt) [self translateText:text direction:bawan::Direction::Automatic trialAttempt:attempt];
        return;
    }
    if (_selectionTrialAttempt) [self cancelTranslation];
    [_translationPanel showForSelection:text];
    [self translateText:text direction:bawan::Direction::Automatic];
    if (_model.setupNotStarted()) {
        [self showOnboarding];
    }
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
    if (_selectionTrialAttempt) [self cancelTranslation];
    if (!_settingsViewController) {
        _settingsViewController = [[SettingsViewController alloc] initWithPreferences:_shortcutPreferences monitor:_shortcut];
        __weak AppDelegate *weakSelf = self;
        _settingsViewController.onLoginSettings = ^{ [weakSelf openLoginSettings:nil]; };
        _settingsViewController.onLoginChanged = ^(BOOL enabled) { [weakSelf setLoginEnabled:enabled]; };
        _settingsViewController.onModelLicense = ^{ [weakSelf showModelLicense:weakSelf]; };
        _settingsViewController.onModelSetup = ^{ [weakSelf beginModelSetup]; };
    }
    [self refreshSettings];
    [_translationPanel showSettings:_settingsViewController];
}

- (void)refreshSettings {
    [_shortcut refresh];
    [self updateShortcutItem];
    [_settingsViewController setLoginStatus:SMAppService.mainAppService.status message:nil error:NO];
    [self pushModelStateToPage:_settingsViewController];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    if (_settingsViewController.view.window.visible) [self refreshSettings];
    else [_shortcut refresh];
    [_onboardingViewController refresh];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [self openTranslation:nil];
    return YES;
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
