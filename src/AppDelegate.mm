#import "AppDelegate.h"
#import "ModelStore.h"
#import "ShortcutMonitor.h"
#import "TranslationPanel.h"
#import "SettingsWindow.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ServiceManagement/ServiceManagement.h>

#include "TranslationEngine.h"
#include <memory>

@interface AppDelegate () <NSMenuDelegate> {
    NSStatusItem *_statusItem;
    NSMenuItem *_modelItem;
    NSMenuItem *_shortcutItem;
    NSMenuItem *_retryItem;
    SettingsWindow *_settingsWindow;
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

    _shortcut = [[ShortcutMonitor alloc] init];
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
        if (owner->_shortcut.listening) {
            [owner->_translationPanel showWithoutChangingInput];
        }
        [owner->_translationPanel setAvailable:owner->_modelReady busy:owner->_busy status:message];
        owner->_statusItem.button.toolTip = message;
    };
    id enabled = [NSUserDefaults.standardUserDefaults objectForKey:@"shortcutEnabled"];
    if (!enabled || [enabled boolValue]) [_shortcut startRequestingPermission:NO];
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
    [menu addItem:_shortcutItem];
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
    if (!_busy) [_translationPanel setAvailable:_modelReady busy:NO status:_modelReady ? @"" : _modelItem.title];
}

- (void)updateShortcutItem {
    _shortcutItem.state = _shortcut.listening ? NSControlStateValueOn : NSControlStateValueOff;
    _shortcutItem.title = _shortcut.listening ? @"Translate with Double ⌘C" : @"Enable Double ⌘C Translation…";
    [_translationPanel setShortcutAvailable:_shortcut.listening];
    [_settingsWindow setShortcutAvailable:_shortcut.listening permissionGranted:CGPreflightListenEventAccess()];
}

- (void)menuWillOpen:(NSMenu *)menu { [self updateShortcutItem]; }

- (void)translateText:(NSString *)text direction:(lore::Direction)direction {
    if (!_modelReady || !_engine || _terminating) return;
    const char *utf8 = text.UTF8String;
    if (!utf8) return;
    _activeRequestId = _engine->translate(std::string(utf8, [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]), direction);
    _busy = YES;
    [_translationPanel setOutput:@"" direction:lore::Direction::Automatic];
    [_translationPanel setAvailable:YES busy:YES status:@""];
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
                @"Output limit reached. The translation is incomplete. Select less text and try again." : @""];
            break;
        case Kind::Cancelled:
            _busy = NO;
            _activeRequestId = 0;
            [_translationPanel setAvailable:_modelReady busy:NO status:@"Translation cancelled"];
            break;
        case Kind::Error:
            _busy = NO;
            _activeRequestId = 0;
            [_translationPanel setAvailable:_modelReady busy:NO status:StringFromUTF8(event.text)];
            break;
        default: break;
    }
}

- (void)cancelTranslation {
    if (!_busy) return;
    _activeRequestId = 0;
    _busy = NO;
    if (_engine) _engine->cancel();
    [_translationPanel setAvailable:_modelReady busy:NO status:@"Translation cancelled"];
}

- (void)openTranslation:(id)sender { [_translationPanel showForManualInput]; }

- (void)toggleShortcut:(id)sender {
    BOOL enable = !_shortcut.listening;
    [NSUserDefaults.standardUserDefaults setBool:enable forKey:@"shortcutEnabled"];
    if (enable) [_shortcut startRequestingPermission:YES];
    else [_shortcut stop];
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

- (void)openInputMonitoring:(id)sender {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"shortcutEnabled"];
    [_shortcut startRequestingPermission:YES];
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]];
    [self updateShortcutItem];
}

- (void)openLoginSettings:(id)sender { [SMAppService openSystemSettingsLoginItems]; }

- (void)setLoginEnabled:(BOOL)enable {
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    BOOL success = enable ? [service registerAndReturnError:&error] : [service unregisterAndReturnError:&error];
    if (!success) {
        [_settingsWindow setLoginStatus:service.status
            message:error.localizedDescription ?: @"Unable to change the launch-at-login setting." error:YES];
    } else {
        [_settingsWindow setLoginStatus:service.status message:nil error:NO];
    }
}

- (void)openSettings:(id)sender {
    if (!_settingsWindow) {
        _settingsWindow = [[SettingsWindow alloc] init];
        __weak AppDelegate *weakSelf = self;
        _settingsWindow.onInputMonitoring = ^{ [weakSelf openInputMonitoring:nil]; };
        _settingsWindow.onLoginSettings = ^{ [weakSelf openLoginSettings:nil]; };
        _settingsWindow.onLoginChanged = ^(BOOL enabled) { [weakSelf setLoginEnabled:enabled]; };
    }
    [self refreshSettings];
    [NSApp activateIgnoringOtherApps:YES];
    [_settingsWindow showWindow:nil];
    [_settingsWindow.window makeKeyAndOrderFront:nil];
}

- (void)refreshSettings {
    // Retry after returning from System Settings without prompting or polling.
    id enabled = [NSUserDefaults.standardUserDefaults objectForKey:@"shortcutEnabled"];
    if ((!enabled || [enabled boolValue]) && !_shortcut.listening) [_shortcut startRequestingPermission:NO];
    [self updateShortcutItem];
    [_settingsWindow setLoginStatus:SMAppService.mainAppService.status message:nil error:NO];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    if (_settingsWindow.window.visible) [self refreshSettings];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [_translationPanel showForManualInput];
    return YES;
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }

- (void)applicationWillTerminate:(NSNotification *)notification {
    _terminating = YES;
    [_shortcut stop];
    [_modelStore cancel];
    if (_engine) {
        _engine->shutdown();
        _engine.reset();
    }
    [NSStatusBar.systemStatusBar removeStatusItem:_statusItem];
}
@end
