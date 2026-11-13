#import "AppDelegate.h"
#import "ModelStore.h"
#import "ShortcutMonitor.h"
#import "TranslationPanel.h"
#import "SettingsViewController.h"
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
    ShortcutPreferences *_shortcutPreferences;
    TranslationPanel *_translationPanel;
    ModelStore *_modelStore;
    ShortcutMonitor *_shortcut;
    std::unique_ptr<bawan::TranslationEngine> _engine;
    uint64_t _activeRequestId;
    uint64_t _engineGeneration;
    NSURL *_modelURL;
    NSString *_pendingText;
    bawan::Direction _pendingDirection;
    BOOL _warmUpWhenAvailable;
    BOOL _modelAvailable;
    BOOL _busy;
    BOOL _terminating;
    BOOL _modelFailed;
    NSString *_modelStatus;
}
@end

@implementation AppDelegate

static NSString *StringFromUTF8(const std::string &text) {
    return [[NSString alloc] initWithBytes:text.data() length:text.size()
                                 encoding:NSUTF8StringEncoding] ?: @"Unable to display the text.";
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _shortcutPreferences = [[ShortcutPreferences alloc] init];
    [self buildMenus];
    _modelStatus = @"Checking the model…";
    _translationPanel = [[TranslationPanel alloc] init];
    __weak AppDelegate *weakSelf = self;
    _translationPanel.onTranslate = ^(NSString *text, bawan::Direction direction) {
        [weakSelf translateText:text direction:direction];
    };
    _translationPanel.onCancel = ^{ [weakSelf cancelTranslation]; };
    _translationPanel.onClose = ^{ [weakSelf cancelTranslation]; };
    _translationPanel.onSettings = ^{ [weakSelf openSettings:nil]; };

    _modelStore = [[ModelStore alloc] init];
    _modelStore.onProgress = ^(double progress, NSString *message) {
        AppDelegate *owner = weakSelf;
        if (!owner || owner->_terminating) return;
        owner->_modelStatus = message;
        [owner updateStatus];
    };
    _modelStore.onReady = ^(NSURL *fileURL) {
        AppDelegate *owner = weakSelf;
        if (!owner || owner->_terminating) return;
        owner->_modelURL = fileURL;
        owner->_modelAvailable = YES;
        owner->_modelFailed = NO;
        owner->_modelStatus = @"Ready to translate · On-device processing";
        if (owner->_pendingText) {
            NSString *text = owner->_pendingText;
            auto direction = owner->_pendingDirection;
            [owner translateText:text direction:direction];
        } else if (owner->_warmUpWhenAvailable) {
            [owner warmUpEngine];
        }
        [owner updateStatus];
    };
    _modelStore.onError = ^(NSString *message) {
        AppDelegate *owner = weakSelf;
        if (!owner || owner->_terminating) return;
        owner->_modelAvailable = NO;
        owner->_modelURL = nil;
        owner->_pendingText = nil;
        owner->_warmUpWhenAvailable = NO;
        owner->_busy = NO;
        owner->_activeRequestId = 0;
        owner->_modelFailed = YES;
        owner->_modelStatus = message;
        [owner updateStatus];
    };

    _shortcut = [[ShortcutMonitor alloc] initWithPreferences:_shortcutPreferences];
    _shortcut.onText = ^(NSString *text) {
        AppDelegate *owner = weakSelf;
        if (!owner || owner->_terminating) return;
        [owner->_translationPanel showForSelection:text];
        [owner translateText:text direction:bawan::Direction::Automatic];
    };
    _shortcut.onProblem = ^(NSString *message) {
        AppDelegate *owner = weakSelf;
        if (!owner || owner->_terminating) return;
        [owner updateShortcutItem];
        [owner->_translationPanel showWithoutChangingInput];
        [owner->_translationPanel setAvailable:owner->_modelAvailable busy:owner->_busy status:message kind:BawanStatusWarning];
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
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"modelLicenseNoticeShown20261109"]) {
        [self showModelLicense:nil];
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"modelLicenseNoticeShown20261109"];
    }
    [_modelStore prepare];
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"firstLaunchShown"]) {
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"firstLaunchShown"];
        [_translationPanel showForManualInput];
    }
}

- (NSMenuItem *)menuItem:(NSString *)title action:(SEL)action key:(NSString *)key {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    item.target = self;
    return item;
}

- (void)showModelLicense:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Built with PLaMo";
    alert.informativeText = @"Bawan uses PLaMo 3 Translate 0.8B under the PLaMo Community License, separately from Bawan’s MIT License. Using the model is subject to PFN’s terms.\n\n"
        "Personal and non-commercial use, including academic use, is free without registration.\n\n"
        "Commercial use includes internal business use. If you or your affiliates’ annual revenue or sales does not exceed JPY 1 billion, register with PFN before commercial use. Above that threshold, a separate commercial agreement is required.\n\n"
        "The model (~573 MB) downloads directly from PFN to your Mac. Review the official terms for your use.";
    [alert addButtonWithTitle:sender ? @"Done" : @"Continue to Model Setup"];
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
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
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
    _modelItem.title = _modelStatus ?: @"Preparing the model…";
    _retryItem.hidden = !_modelFailed;
    _retryItem.enabled = _modelFailed;
    _statusItem.button.toolTip = [@"Bawan — " stringByAppendingString:_modelItem.title];
    if (!_busy) [_translationPanel setAvailable:_modelAvailable busy:NO status:_modelAvailable ? @"" : _modelItem.title
                                         kind:_modelFailed ? BawanStatusError : BawanStatusInformation];
    else if (!_modelAvailable) [_translationPanel setAvailable:NO busy:YES status:_modelItem.title
                                                        kind:_modelFailed ? BawanStatusError : BawanStatusInformation];
}

- (void)updateShortcutItem {
    NSMutableArray<NSString *> *instructions = [NSMutableArray array];
    BOOL needsPermission = NO;
    for (NSMenuItem *item in @[_shortcutItem, _panelShortcutItem]) {
        auto action = static_cast<bawan::ShortcutAction>(item.tag);
        auto binding = [_shortcutPreferences bindingForAction:action];
        ShortcutAvailability availability = [_shortcut availabilityForAction:action];
        item.state = binding.enabled ? NSControlStateValueOn : NSControlStateValueOff;
        NSString *verb = action == bawan::ShortcutAction::TranslateSelection ? @"Selection Translation" : @"Open Translator";
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
}

- (void)shortcutPreferencesDidChange:(NSNotification *)notification { [self updateShortcutItem]; }

- (void)menuWillOpen:(NSMenu *)menu {
    [_shortcut refresh];
    [self updateShortcutItem];
}

- (void)ensureEngine {
    if (_engine || !_modelAvailable || !_modelURL || _terminating) return;
    const uint64_t generation = ++_engineGeneration;
    __weak AppDelegate *weakSelf = self;
    auto mailbox = std::make_shared<bawan::EngineEventMailbox>();
    _engine = std::make_unique<bawan::TranslationEngine>(
        std::string(_modelURL.fileSystemRepresentation), [weakSelf, generation, mailbox](bawan::EngineEvent event) {
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
    _warmUpWhenAvailable = !_modelAvailable;
    [self ensureEngine];
    if (_engine) _engine->warmUp();
}

- (void)translateText:(NSString *)text direction:(bawan::Direction)direction {
    if (_terminating) return;
    if (!_modelAvailable) {
        if (_modelFailed) { [self updateStatus]; return; }
        // Keep only the latest selection while the model file is being verified
        // or downloaded. Closing/cancelling clears it before setup completes.
        _pendingText = [text copy];
        _pendingDirection = direction;
        _activeRequestId = 0;
        _busy = YES;
        [_translationPanel setOutput:@"" direction:bawan::Direction::Automatic];
        [self updateStatus];
        return;
    }
    _pendingText = nil;
    _warmUpWhenAvailable = NO;
    [self ensureEngine];
    const char *utf8 = text.UTF8String;
    if (!utf8) return;
    _activeRequestId = _engine->translate(std::string(utf8, [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]), direction);
    _busy = YES;
    [_translationPanel setOutput:@"" direction:bawan::Direction::Automatic];
    [_translationPanel setAvailable:YES busy:YES status:@"" kind:BawanStatusInformation];
}

- (void)handleEngineEvent:(const bawan::EngineEvent &)event {
    using Kind = bawan::EngineEvent::Kind;
    if (event.requestId == 0) {
        // Availability describes the verified file, independently of whether
        // inference resources are currently loaded or have expired after idle.
        if (event.kind == Kind::Idle) return;
        if (event.kind == Kind::Loading) {
            _modelFailed = NO;
            _modelStatus = @"Loading the model…";
        } else if (event.kind == Kind::Ready || event.kind == Kind::Cancelled) {
            _modelFailed = NO;
            _modelStatus = @"Ready to translate · On-device processing";
        } else if (event.kind == Kind::Error) {
            _modelFailed = YES;
            _modelStatus = StringFromUTF8(event.text);
        }
        [self updateStatus];
        [_translationPanel setAvailable:_modelAvailable busy:_busy
            status:event.kind == Kind::Ready || event.kind == Kind::Cancelled ? @"" : _modelStatus
            kind:event.kind == Kind::Error ? BawanStatusError : BawanStatusInformation];
        return;
    }
    if (event.requestId != _activeRequestId) return;
    switch (event.kind) {
        case Kind::Text:
            [_translationPanel setOutput:StringFromUTF8(event.text) direction:event.direction];
            break;
        case Kind::Complete:
            _busy = NO;
            _activeRequestId = 0;
            [_translationPanel setOutput:StringFromUTF8(event.text) direction:event.direction];
            [_translationPanel setAvailable:_modelAvailable busy:NO status:event.truncated ?
                @"Output limit reached. The translation is incomplete. Select less text and try again." : @""
                                      kind:event.truncated ? BawanStatusWarning : BawanStatusInformation];
            break;
        case Kind::Cancelled:
            _busy = NO;
            _activeRequestId = 0;
            [_translationPanel setAvailable:_modelAvailable busy:NO status:@"Translation cancelled" kind:BawanStatusInformation];
            break;
        case Kind::Error:
            _busy = NO;
            _activeRequestId = 0;
            [_translationPanel setAvailable:_modelAvailable busy:NO status:StringFromUTF8(event.text) kind:BawanStatusError];
            break;
        default: break;
    }
}

- (void)cancelTranslation {
    _pendingText = nil;
    _warmUpWhenAvailable = NO;
    if (_engine) _engine->cancel();
    if (_modelAvailable && !_modelFailed) _modelStatus = @"Ready to translate · On-device processing";
    if (!_busy) { [self updateStatus]; return; }
    _activeRequestId = 0;
    _busy = NO;
    [self updateStatus];
    [_translationPanel setAvailable:_modelAvailable busy:NO status:@"Translation cancelled" kind:BawanStatusInformation];
}

- (void)openTranslation:(id)sender {
    [_translationPanel showForManualInput];
    [self warmUpEngine];
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
    _modelURL = nil;
    _modelAvailable = NO;
    _modelFailed = NO;
    _modelStatus = @"Checking the model…";
    [self updateStatus];
    [_modelStore prepare];
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
    }
    [self refreshSettings];
    [_translationPanel showSettings:_settingsViewController];
}

- (void)refreshSettings {
    // Retry after returning from System Settings without prompting or polling.
    [_shortcut refresh];
    [self updateShortcutItem];
    [_settingsViewController setLoginStatus:SMAppService.mainAppService.status message:nil error:NO];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    // One activation owner retries permissions even when Settings is closed.
    if (_settingsViewController.view.window.visible) [self refreshSettings];
    else [_shortcut refresh];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [self openTranslation:nil];
    return YES;
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }

- (void)applicationWillTerminate:(NSNotification *)notification {
    _terminating = YES;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_shortcut stop];
    [_modelStore cancel];
    if (_engine) {
        _engine->shutdown();
        _engine.reset();
    }
    [NSStatusBar.systemStatusBar removeStatusItem:_statusItem];
}
@end
