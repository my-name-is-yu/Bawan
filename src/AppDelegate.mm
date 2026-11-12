#import "AppDelegate.h"
#import "ModelStore.h"
#import "ShortcutMonitor.h"
#import "TranslationPanel.h"
#import <ServiceManagement/ServiceManagement.h>

#include "TranslationEngine.h"
#include <memory>

@interface AppDelegate () <NSMenuDelegate> {
    NSStatusItem *_statusItem;
    NSMenuItem *_modelItem;
    NSMenuItem *_shortcutItem;
    NSMenuItem *_retryItem;
    NSTextField *_settingsHint;
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
                                 encoding:NSUTF8StringEncoding] ?: @"文字列を表示できませんでした。";
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self buildMenus];
    _modelStatus = @"モデルを確認しています…";
    _translationPanel = [[TranslationPanel alloc] init];
    __weak AppDelegate *weakSelf = self;
    _translationPanel.onTranslate = ^(NSString *text, NSInteger direction) {
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
        owner->_modelStatus = @"モデルを読み込んでいます…";
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
            [owner translateText:text direction:owner->_translationPanel.directionIndex];
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
    NSImage *image = [NSImage imageWithSystemSymbolName:@"character.bubble" accessibilityDescription:@"Lore 翻訳"];
    if (image) {
        image.template = YES;
        _statusItem.button.image = image;
    } else {
        _statusItem.button.title = @"訳";
    }
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Lore"];
    menu.autoenablesItems = NO;
    menu.delegate = self;
    _modelItem = [self menuItem:@"モデルを準備しています…" action:NULL key:@""];
    _modelItem.enabled = NO;
    [menu addItem:_modelItem];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self menuItem:@"翻訳画面を開く" action:@selector(openTranslation:) key:@""]];
    _shortcutItem = [self menuItem:@"⌘C 2回で翻訳" action:@selector(toggleShortcut:) key:@""];
    [menu addItem:_shortcutItem];
    _retryItem = [self menuItem:@"モデルの準備を再試行" action:@selector(retryModel:) key:@""];
    _retryItem.hidden = YES;
    [menu addItem:_retryItem];
    [menu addItem:[self menuItem:@"設定…" action:@selector(openSettings:) key:@","]];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self menuItem:@"Loreを終了" action:@selector(quit:) key:@"q"]];
    _statusItem.menu = menu;

    // Native editing commands are required when the nonactivating panel becomes key.
    NSMenu *main = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"Lore" action:NULL keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Lore"];
    [appMenu addItem:[self menuItem:@"設定…" action:@selector(openSettings:) key:@","]];
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItem:[self menuItem:@"Loreを終了" action:@selector(quit:) key:@"q"]];
    appItem.submenu = appMenu;
    [main addItem:appItem];
    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"編集" action:NULL keyEquivalent:@""];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"編集"];
    NSArray<NSString *> *titles = @[@"取り消す", @"やり直す", @"カット", @"コピー", @"ペースト", @"すべてを選択"];
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
    _modelItem.title = _modelStatus ?: @"モデルを準備しています…";
    _retryItem.hidden = !_modelFailed;
    _retryItem.enabled = _modelFailed;
    _statusItem.button.toolTip = [@"Lore — " stringByAppendingString:_modelItem.title];
    if (!_busy) [_translationPanel setAvailable:_modelReady busy:NO status:_modelItem.title];
}

- (void)updateShortcutItem {
    _shortcutItem.state = _shortcut.listening ? NSControlStateValueOn : NSControlStateValueOff;
    _shortcutItem.title = _shortcut.listening ? @"⌘C 2回で翻訳" : @"⌘C 2回で翻訳を有効にする…";
    [_translationPanel setShortcutAvailable:_shortcut.listening];
}

- (void)menuWillOpen:(NSMenu *)menu { [self updateShortcutItem]; }

- (void)translateText:(NSString *)text direction:(NSInteger)direction {
    if (!_modelReady || !_engine || _terminating) return;
    const char *utf8 = text.UTF8String;
    if (!utf8) return;
    lore::Direction target = direction == 1 ? lore::Direction::EnglishToJapanese :
        direction == 2 ? lore::Direction::JapaneseToEnglish : lore::Direction::Automatic;
    _activeRequestId = _engine->translate(std::string(utf8, [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]), target);
    _busy = YES;
    [_translationPanel setOutput:@""];
    [_translationPanel setAvailable:YES busy:YES status:@"翻訳しています…"];
}

- (void)handleEngineEvent:(const lore::EngineEvent &)event {
    using Kind = lore::EngineEvent::Kind;
    if (event.requestId == 0) {
        if (event.kind == Kind::Loading) {
            _modelReady = NO;
            _modelFailed = NO;
            _modelStatus = @"モデルを読み込んでいます…";
        } else if (event.kind == Kind::Ready) {
            _modelReady = YES;
            _modelFailed = NO;
            _modelStatus = @"翻訳できます · 端末内で処理";
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
            [_translationPanel setOutput:StringFromUTF8(event.text)];
            break;
        case Kind::Complete:
            _busy = NO;
            _activeRequestId = 0;
            [_translationPanel setOutput:StringFromUTF8(event.text)];
            [_translationPanel setAvailable:_modelReady busy:NO status:event.truncated ?
                @"生成上限に達しました。訳文は途中までです。範囲を短くして再翻訳してください。" : @"翻訳しました"];
            break;
        case Kind::Cancelled:
            _busy = NO;
            _activeRequestId = 0;
            [_translationPanel setAvailable:_modelReady busy:NO status:@"翻訳を中止しました"];
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
    [_translationPanel setAvailable:_modelReady busy:NO status:@"翻訳を中止しました"];
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
    _modelStatus = @"モデルを確認しています…";
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

- (void)setLoginEnabled:(NSButton *)sender {
    SMAppService *service = SMAppService.mainAppService;
    BOOL enable = sender.state == NSControlStateValueOn;
    NSError *error = nil;
    BOOL success = enable ? [service registerAndReturnError:&error] : [service unregisterAndReturnError:&error];
    if (!success) {
        sender.state = service.status == SMAppServiceStatusEnabled || service.status == SMAppServiceStatusRequiresApproval ?
            NSControlStateValueOn : NSControlStateValueOff;
        _settingsHint.stringValue = error.localizedDescription ?: @"ログイン時の起動設定を変更できませんでした。";
    } else {
        _settingsHint.stringValue = service.status == SMAppServiceStatusRequiresApproval ?
            @"システム設定の「ログイン項目」でLoreを許可してください。" : @"ログイン時の起動設定を変更しました。";
    }
}

- (void)openSettings:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Loreの設定";
    alert.informativeText = @"⌘Cを2回押して翻訳するには「入力監視」でLoreを許可してください。許可がなくても手入力で使えます。";
    [alert addButtonWithTitle:@"閉じる"];
    NSButton *permissions = [NSButton buttonWithTitle:@"入力監視の設定を開く…" target:self action:@selector(openInputMonitoring:)];
    NSButton *login = [NSButton checkboxWithTitle:@"ログイン時にLoreを起動する" target:self action:@selector(setLoginEnabled:)];
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    login.state = status == SMAppServiceStatusEnabled || status == SMAppServiceStatusRequiresApproval ? NSControlStateValueOn : NSControlStateValueOff;
    NSButton *loginSettings = [NSButton buttonWithTitle:@"ログイン項目の設定を開く…" target:self action:@selector(openLoginSettings:)];
    _settingsHint = [NSTextField wrappingLabelWithString:@"モデルと翻訳処理は、このアプリ内で動作します。"];
    _settingsHint.font = [NSFont systemFontOfSize:12];
    _settingsHint.textColor = NSColor.secondaryLabelColor;
    _settingsHint.preferredMaxLayoutWidth = 360;
    NSStackView *options = [NSStackView stackViewWithViews:@[permissions, login, loginSettings, _settingsHint]];
    options.orientation = NSUserInterfaceLayoutOrientationVertical;
    options.alignment = NSLayoutAttributeLeading;
    options.spacing = 12;
    [options.widthAnchor constraintEqualToConstant:360].active = YES;
    [_settingsHint.widthAnchor constraintEqualToAnchor:options.widthAnchor].active = YES;
    // NSAlert reserves its accessory's frame, rather than solving its size
    // constraints. Lay out the wrapping label at the intended width first.
    options.frame = NSMakeRect(0, 0, 360, 160);
    [options layoutSubtreeIfNeeded];
    [options setFrameSize:NSMakeSize(360, MAX(160, options.fittingSize.height))];
    [options layoutSubtreeIfNeeded];
    alert.accessoryView = options;
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
    _settingsHint = nil;
    // TCC grants can become available after visiting System Settings; no polling is needed.
    id enabled = [NSUserDefaults.standardUserDefaults objectForKey:@"shortcutEnabled"];
    if (!enabled || [enabled boolValue]) [_shortcut startRequestingPermission:NO];
    [self updateShortcutItem];
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
