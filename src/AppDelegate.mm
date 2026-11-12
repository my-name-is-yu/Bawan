#import "AppDelegate.h"
#import "ModelStore.h"
#import "ShortcutMonitor.h"
#import "TranslationPanel.h"
#import "SettingsViewController.h"
#import <ServiceManagement/ServiceManagement.h>

#include "TranslationEngine.h"
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
    std::unique_ptr<lore::TranslationEngine> _engine;
    uint64_t _activeRequestId;
    BOOL _modelReady;
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
    _translationPanel.onTranslate = ^(NSString *text, lore::Direction direction) {
        [weakSelf translateText:text direction:direction];
    };
    _translationPanel.onCancel = ^{ [weakSelf cancelTranslation]; };
    _translationPanel.onClose = ^{ [weakSelf cancelTranslation]; };
    _translationPanel.onSettings = ^{ [weakSelf openSettings:nil]; };

    _engine = std::make_unique<lore::TranslationEngine>([weakSelf](lore::EngineEvent event) {
        @autoreleasepool {
            dispatch_async(dispatch_get_main_queue(), ^{
                AppDelegate *owner = weakSelf;
                if (owner && !owner->_terminating) [owner handleEngineEvent:event];
            });
        }
    });
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
        owner->_modelStatus = @"Loading the model…";
        [owner updateStatus];
        owner->_engine->loadModel(fileURL.fileSystemRepresentation);
    };
    _modelStore.onError = ^(NSString *message) {
        AppDelegate *owner = weakSelf;
        if (!owner || owner->_terminating) return;
        owner->_modelReady = NO;
        owner->_modelFailed = YES;
        owner->_modelStatus = message;
        [owner updateStatus];
    };

    _shortcut = [[ShortcutMonitor alloc] initWithPreferences:_shortcutPreferences];
    _shortcut.onText = ^(NSString *text) {
        AppDelegate *owner = weakSelf;
        if (!owner || owner->_terminating) return;
        [owner->_translationPanel showForSelection:text];
        if (owner->_modelReady) {
            [owner translateText:text direction:lore::Direction::Automatic];
        } else {
            [owner updateStatus];
        }
    };
    _shortcut.onProblem = ^(NSString *message) {
        AppDelegate *owner = weakSelf;
        if (!owner || owner->_terminating) return;
        [owner updateShortcutItem];
        [owner->_translationPanel showWithoutChangingInput];
        [owner->_translationPanel setAvailable:owner->_modelReady busy:owner->_busy status:message kind:LoreStatusWarning];
        owner->_statusItem.button.toolTip = message;
    };
    _shortcut.onOpenPanel = ^{
        AppDelegate *owner = weakSelf;
        if (owner && !owner->_terminating) [owner->_translationPanel showForManualInput];
    };
    _shortcut.onAvailabilityChanged = ^{
        AppDelegate *owner = weakSelf;
        if (owner && !owner->_terminating) [owner updateShortcutItem];
    };
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(shortcutPreferencesDidChange:)
        name:LoreShortcutsDidChangeNotification object:_shortcutPreferences];
    [_shortcut start];
    [self updateShortcutItem];
    [self updateStatus];
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

- (void)buildMenus {
    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"character.bubble" accessibilityDescription:@"Lore Translator"];
    if (image) {
        [image setTemplate:YES];
        _statusItem.button.image = image;
    } else {
        _statusItem.button.title = @"L";
    }
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Lore"];
    menu.autoenablesItems = NO;
    menu.delegate = self;
    _modelItem = [self menuItem:@"Preparing the model…" action:NULL key:@""];
    _modelItem.enabled = NO;
    [menu addItem:_modelItem];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self menuItem:@"Open Translator" action:@selector(openTranslation:) key:@""]];
    _shortcutItem = [self menuItem:@"Translate with Double ⌘C" action:@selector(toggleShortcut:) key:@""];
    _shortcutItem.tag = static_cast<NSInteger>(lore::ShortcutAction::TranslateSelection);
    [menu addItem:_shortcutItem];
    _panelShortcutItem = [self menuItem:@"Open Translator with Double ⌥T" action:@selector(toggleShortcut:) key:@""];
    _panelShortcutItem.tag = static_cast<NSInteger>(lore::ShortcutAction::OpenPanel);
    [menu addItem:_panelShortcutItem];
    _retryItem = [self menuItem:@"Retry Model Setup" action:@selector(retryModel:) key:@""];
    _retryItem.hidden = YES;
    [menu addItem:_retryItem];
    [menu addItem:[self menuItem:@"Settings…" action:@selector(openSettings:) key:@","]];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self menuItem:@"Quit Lore" action:@selector(quit:) key:@"q"]];
    _statusItem.menu = menu;

    // Native editing commands are required when the nonactivating panel becomes key.
    NSMenu *main = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"Lore" action:NULL keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Lore"];
    [appMenu addItem:[self menuItem:@"Settings…" action:@selector(openSettings:) key:@","]];
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItem:[self menuItem:@"Quit Lore" action:@selector(quit:) key:@"q"]];
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
    _statusItem.button.toolTip = [@"Lore — " stringByAppendingString:_modelItem.title];
    if (!_busy) [_translationPanel setAvailable:_modelReady busy:NO status:_modelReady ? @"" : _modelItem.title
                                         kind:_modelFailed ? LoreStatusError : LoreStatusInformation];
}

- (void)updateShortcutItem {
    NSMutableArray<NSString *> *instructions = [NSMutableArray array];
    BOOL needsPermission = NO;
    for (NSMenuItem *item in @[_shortcutItem, _panelShortcutItem]) {
        auto action = static_cast<lore::ShortcutAction>(item.tag);
        auto binding = [_shortcutPreferences bindingForAction:action];
        ShortcutAvailability availability = [_shortcut availabilityForAction:action];
        item.state = binding.enabled ? NSControlStateValueOn : NSControlStateValueOff;
        NSString *verb = action == lore::ShortcutAction::TranslateSelection ? @"Selection Translation" : @"Open Translator";
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

- (void)translateText:(NSString *)text direction:(lore::Direction)direction {
    if (!_modelReady || !_engine || _terminating) return;
    const char *utf8 = text.UTF8String;
    if (!utf8) return;
    _activeRequestId = _engine->translate(std::string(utf8, [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]), direction);
    _busy = YES;
    [_translationPanel setOutput:@"" direction:lore::Direction::Automatic];
    [_translationPanel setAvailable:YES busy:YES status:@"" kind:LoreStatusInformation];
}

- (void)handleEngineEvent:(const lore::EngineEvent &)event {
    using Kind = lore::EngineEvent::Kind;
    if (event.requestId == 0) {
        if (event.kind == Kind::Loading) {
            _modelReady = NO;
            _modelFailed = NO;
            _modelStatus = @"Loading the model…";
        } else if (event.kind == Kind::Ready) {
            _modelReady = YES;
            _modelFailed = NO;
            _modelStatus = @"Ready to translate · On-device processing";
        } else if (event.kind == Kind::Error) {
            _modelReady = NO;
            _modelFailed = YES;
            _modelStatus = StringFromUTF8(event.text);
        }
        [self updateStatus];
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
            [_translationPanel setAvailable:_modelReady busy:NO status:event.truncated ?
                @"Output limit reached. The translation is incomplete. Select less text and try again." : @""
                                      kind:event.truncated ? LoreStatusWarning : LoreStatusInformation];
            break;
        case Kind::Cancelled:
            _busy = NO;
            _activeRequestId = 0;
            [_translationPanel setAvailable:_modelReady busy:NO status:@"Translation cancelled" kind:LoreStatusInformation];
            break;
        case Kind::Error:
            _busy = NO;
            _activeRequestId = 0;
            [_translationPanel setAvailable:_modelReady busy:NO status:StringFromUTF8(event.text) kind:LoreStatusError];
            break;
        default: break;
    }
}

- (void)cancelTranslation {
    if (!_busy) return;
    _activeRequestId = 0;
    _busy = NO;
    if (_engine) _engine->cancel();
    [_translationPanel setAvailable:_modelReady busy:NO status:@"Translation cancelled" kind:LoreStatusInformation];
}

- (void)openTranslation:(id)sender { [_translationPanel showForManualInput]; }

- (void)toggleShortcut:(NSMenuItem *)sender {
    auto action = static_cast<lore::ShortcutAction>(sender.tag);
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
    _modelReady = NO;
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
    if (_settingsViewController.view.window.visible) [self refreshSettings];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [_translationPanel showForManualInput];
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
