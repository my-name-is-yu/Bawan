#import "ShortcutMonitor.h"
#import "SelectionReader.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>

#include <array>

namespace {
constexpr unsigned selectionIndex = static_cast<unsigned>(bawan::ShortcutAction::TranslateSelection);
constexpr unsigned panelIndex = static_cast<unsigned>(bawan::ShortcutAction::OpenPanel);
}

@interface ShortcutMonitor () {
    ShortcutPreferences *_preferences;
    SelectionReader *_selectionReader;
    bawan::ShortcutBindings _bindings;
    std::array<bawan::ShortcutGesture, 2> _gestures;
    std::array<ShortcutAvailability, 2> _availability;
    std::array<bool, 128> _swallowed;
    std::array<NSUInteger, 128> _swallowedRevision;
    NSUInteger _gestureRevision;
    CFMachPortRef _passiveTap;
    CFMachPortRef _activeTap;
    CFRunLoopSourceRef _passiveSource;
    CFRunLoopSourceRef _activeSource;
    BOOL _started;
    BOOL _asleep;
    BOOL _suspended;
    BOOL _configurationActive;
    BOOL _awaitingCopyRelease;
    std::uint16_t _copyReleaseKey;
    NSUInteger _actionGeneration;
    NSMutableArray<id> *_workspaceObservers;
    id _preferencesObserver;
}
- (BOOL)handleEventType:(CGEventType)type event:(CGEventRef)event active:(BOOL)active;
- (void)cancelPending;
- (void)configureGestures;
- (void)applyPreferences;
- (BOOL)installTapActive:(BOOL)active;
- (void)removeTapActive:(BOOL)active;
@end

static CGEventRef observePassive(CGEventTapProxy, CGEventType type, CGEventRef event, void *context) {
    @autoreleasepool {
        [(__bridge ShortcutMonitor *)context handleEventType:type event:event active:NO];
    }
    return event;
}

static CGEventRef observeActive(CGEventTapProxy, CGEventType type, CGEventRef event, void *context) {
    @autoreleasepool {
        if ([(__bridge ShortcutMonitor *)context handleEventType:type event:event active:YES]) return nullptr;
    }
    return event;
}

@implementation ShortcutMonitor

- (instancetype)initWithPreferences:(ShortcutPreferences *)preferences {
    return [self initWithPreferences:preferences selectionReader:[SelectionReader new]];
}

- (instancetype)initWithPreferences:(ShortcutPreferences *)preferences selectionReader:(SelectionReader *)selectionReader {
    self = [super init];
    if (!self) return nil;
    _preferences = preferences;
    _selectionReader = selectionReader;
    _bindings = preferences.bindings;
    _availability.fill(ShortcutAvailabilityOff);
    [self configureGestures];
    return self;
}

- (void)configureGestures {
    ++_gestureRevision;
    for (unsigned i = 0; i < _gestures.size(); ++i) {
        _gestures[i].configure(_bindings[i], !(i == selectionIndex && bawan::isPassiveCopy(_bindings[i])));
    }
}

- (void)cancelPending {
    ++_actionGeneration;
    [_selectionReader cancel];
    _awaitingCopyRelease = NO;
    for (auto &gesture : _gestures) gesture.cancel();
}

- (void)applyPreferences {
    [self cancelPending];
    _bindings = _preferences.bindings;
    [self configureGestures];
    [self refresh];
}

- (void)start {
    NSAssert(NSThread.isMainThread, @"Shortcut monitoring runs on the main thread");
    if (_started) { [self refresh]; return; }
    _started = YES;
    _asleep = NO;
    _workspaceObservers = [NSMutableArray array];
    NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    __weak ShortcutMonitor *weakSelf = self;
    [_workspaceObservers addObject:[workspace addObserverForName:NSWorkspaceDidActivateApplicationNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *) {
        ShortcutMonitor *self = weakSelf;
        if (!self) return;
        [self cancelPending];
        [self refresh];
    }]];
    [_workspaceObservers addObject:[workspace addObserverForName:NSWorkspaceWillSleepNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *) {
        ShortcutMonitor *self = weakSelf;
        if (!self) return;
        self->_asleep = YES;
        [self cancelPending];
        self->_swallowed.fill(false);
        [self removeTapActive:NO];
        [self removeTapActive:YES];
        [self configureGestures];
    }]];
    [_workspaceObservers addObject:[workspace addObserverForName:NSWorkspaceDidWakeNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *) {
        ShortcutMonitor *self = weakSelf;
        if (!self) return;
        self->_asleep = NO;
        [self cancelPending];
        [self configureGestures];
        [self refresh];
    }]];
    _preferencesObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:BawanShortcutsDidChangeNotification object:_preferences
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *) { [weakSelf applyPreferences]; }];
    [self applyPreferences];
}

- (void)stop {
    NSAssert(NSThread.isMainThread, @"Shortcut monitoring runs on the main thread");
    _started = NO;
    [self cancelPending];
    _swallowed.fill(false);
    [self removeTapActive:NO];
    [self removeTapActive:YES];
    for (auto &gesture : _gestures) gesture.reset();
    NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    for (id observer in _workspaceObservers) [workspace removeObserver:observer];
    _workspaceObservers = nil;
    if (_preferencesObserver) [NSNotificationCenter.defaultCenter removeObserver:_preferencesObserver];
    _preferencesObserver = nil;
    [self refresh];
}

- (BOOL)suspended { return _suspended; }
- (void)setSuspended:(BOOL)suspended {
    if (_suspended == suspended) return;
    _suspended = suspended;
    [self cancelPending];
    [self configureGestures];
    [self refresh];
}

- (BOOL)configurationActive { return _configurationActive; }
- (void)setConfigurationActive:(BOOL)active {
    if (_configurationActive == active) return;
    _configurationActive = active;
    [self cancelPending];
}

- (BOOL)installTapActive:(BOOL)active {
    CFMachPortRef &tap = active ? _activeTap : _passiveTap;
    CFRunLoopSourceRef &source = active ? _activeSource : _passiveSource;
    if (tap) {
        CGEventTapEnable(tap, true);
        if (CGEventTapIsEnabled(tap)) return YES;
        [self removeTapActive:active];
    }
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
    if (active) mask |= CGEventMaskBit(kCGEventFlagsChanged);
    tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
        active ? kCGEventTapOptionDefault : kCGEventTapOptionListenOnly,
        mask, active ? observeActive : observePassive, (__bridge void *)self);
    if (tap) source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    if (!tap || !source) {
        [self removeTapActive:active];
        return NO;
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);
    return CGEventTapIsEnabled(tap);
}

- (void)removeTapActive:(BOOL)active {
    CFMachPortRef &tap = active ? _activeTap : _passiveTap;
    CFRunLoopSourceRef &source = active ? _activeSource : _passiveSource;
    if (source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
        CFRunLoopSourceInvalidate(source);
        CFRelease(source);
        source = nullptr;
    }
    if (tap) {
        CGEventTapEnable(tap, false);
        CFMachPortInvalidate(tap);
        CFRelease(tap);
        tap = nullptr;
    }
}

- (void)refresh {
    NSAssert(NSThread.isMainThread, @"Shortcut monitoring runs on the main thread");
    const bool inputAllowed = CGPreflightListenEventAccess();
    const bool accessibilityAllowed = AXIsProcessTrusted();
    const bool hadPassiveTap = _passiveTap != nullptr;
    const bool hadActiveTap = _activeTap != nullptr;
    if (!_activeTap || !CGEventTapIsEnabled(_activeTap)) {
        // Key-up may have happened while a timed-out tap was disabled. Keep
        // swallowing held keys, but never swallow a future unrelated press.
        for (unsigned key = 0; key < _swallowed.size(); ++key) {
            if (_swallowed[key] && !CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, key)) {
                _swallowed[key] = false;
            }
        }
    }
    bool wantsPassive = false;
    bool wantsActive = false;
    for (unsigned i = 0; i < _bindings.size(); ++i) {
        if (!_bindings[i].enabled) continue;
        if (i == selectionIndex && bawan::isPassiveCopy(_bindings[i])) wantsPassive = true;
        else wantsActive = true;
    }
    const bool running = _started && !_asleep && !_suspended;
    if (running && wantsPassive && inputAllowed) [self installTapActive:NO];
    else [self removeTapActive:NO];
    bool draining = false;
    for (bool swallowed : _swallowed) draining |= swallowed;
    if (_started && !_asleep && accessibilityAllowed && ((running && wantsActive) || draining)) {
        [self installTapActive:YES];
    } else {
        [self removeTapActive:YES];
        if (!accessibilityAllowed) _swallowed.fill(false);
    }
    if (hadPassiveTap != (_passiveTap != nullptr) || hadActiveTap != (_activeTap != nullptr)) {
        [self cancelPending];
        [self configureGestures];
    }
    bool changed = false;
    for (unsigned i = 0; i < _bindings.size(); ++i) {
        ShortcutAvailability state = ShortcutAvailabilityOff;
        if (_started && _bindings[i].enabled) {
            const bool passive = i == selectionIndex && bawan::isPassiveCopy(_bindings[i]);
            if (passive && !inputAllowed) state = ShortcutAvailabilityNeedsInputMonitoring;
            else if (!passive && !accessibilityAllowed) state = ShortcutAvailabilityNeedsAccessibility;
            else if (_suspended || _asleep) state = _availability[i];
            else {
                CFMachPortRef tap = passive ? _passiveTap : _activeTap;
                state = tap && CGEventTapIsEnabled(tap) ? ShortcutAvailabilityAvailable : ShortcutAvailabilityFailed;
            }
        }
        changed |= state != _availability[i];
        _availability[i] = state;
    }
    if (changed && self.onAvailabilityChanged) self.onAvailabilityChanged();
}

- (ShortcutAvailability)availabilityForAction:(bawan::ShortcutAction)action {
    return _availability[static_cast<unsigned>(action)];
}

- (void)requestPermissionForAction:(bawan::ShortcutAction)action {
    const auto binding = [_preferences bindingForAction:action];
    NSString *pane = nil;
    if (action == bawan::ShortcutAction::TranslateSelection && bawan::isPassiveCopy(binding)) {
        if (!CGPreflightListenEventAccess()) {
            CGRequestListenEventAccess();
            pane = @"Privacy_ListenEvent";
        }
    } else if (!AXIsProcessTrusted()) {
        NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
        pane = @"Privacy_Accessibility";
    }
    if (pane) {
        NSString *url = [@"x-apple.systempreferences:com.apple.preference.security?" stringByAppendingString:pane];
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:url]];
    }
    [self refresh];
}

- (BOOL)handleEventType:(CGEventType)type event:(CGEventRef)event active:(BOOL)active {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        [self cancelPending];
        [self configureGestures];
        __weak ShortcutMonitor *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
        return NO;
    }
    if (!_started || _asleep || !event) return NO;
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == bawan::selectionCopyEventTag) return NO;
    if (type != kCGEventKeyDown && type != kCGEventKeyUp && type != kCGEventFlagsChanged) return NO;

    const auto key = static_cast<std::uint16_t>(CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode));
    const bool repeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
    const bool owned = active && key < _swallowed.size() && _swallowed[key];
    bool consumed = owned && (type == kCGEventKeyDown || type == kCGEventKeyUp);
    if (active && type == kCGEventKeyUp && key < _swallowed.size()) _swallowed[key] = false;
    const auto modifiers = ShortcutModifiersFromFlags(static_cast<NSEventModifierFlags>(CGEventGetFlags(event)), key);
    // A nonactivating panel can own keyboard input while another app stays frontmost.
    NSWindow *keyWindow = NSApp.keyWindow;
    const bool nativeCommand = keyWindow.isKeyWindow && keyWindow.visible &&
        bawan::isNativeWindowShortcut(key, modifiers);
    if (_suspended || _configurationActive || nativeCommand) {
        if (_configurationActive || nativeCommand) {
            [self cancelPending];
            [self configureGestures];
        }
        // Previously intercepted downs still own their repeats and release.
        if (active && type == kCGEventKeyUp) {
            __weak ShortcutMonitor *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
        }
        return consumed;
    }

    const pid_t application = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    const bawan::ShortcutEvent input = {
        type == kCGEventKeyDown ? bawan::ShortcutEvent::Kind::KeyDown :
            type == kCGEventKeyUp ? bawan::ShortcutEvent::Kind::KeyUp : bawan::ShortcutEvent::Kind::FlagsChanged,
        key, modifiers,
        repeat, application, CGEventGetTimestamp(event)
    };
    if (_awaitingCopyRelease && type == kCGEventKeyDown && key != _copyReleaseKey) {
        [self cancelPending];
    }
    for (unsigned i = 0; i < _bindings.size(); ++i) {
        const bool passive = i == selectionIndex && bawan::isPassiveCopy(_bindings[i]);
        if (!_bindings[i].enabled || passive == static_cast<bool>(active)) continue;
        if (owned && type == kCGEventKeyDown && _swallowedRevision[key] != _gestureRevision) continue;
        const auto result = _gestures[i].handle(input);
        consumed |= result.consumed;
        if (active && result.consumed && type == kCGEventKeyDown && key < _swallowed.size()) {
            _swallowed[key] = true;
            _swallowedRevision[key] = _gestureRevision;
        }
        if (result.firstPress) {
            ++_actionGeneration;
            [_selectionReader cancel];
            _awaitingCopyRelease = NO;
            if (passive) [_selectionReader beginCopyFromApplication:application passive:YES];
        }
        if (!result.triggered) continue;
        if (i == selectionIndex) {
            if (passive) {
                [_selectionReader readSelection];
            } else {
                ++_actionGeneration;
                [_selectionReader beginCopyFromApplication:application passive:NO];
                _awaitingCopyRelease = YES;
                _copyReleaseKey = key;
            }
        } else if (i == panelIndex) {
            const NSUInteger generation = ++_actionGeneration;
            [_selectionReader cancel];
            _awaitingCopyRelease = NO;
            __weak ShortcutMonitor *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                ShortcutMonitor *self = weakSelf;
                if (!self || !self->_started || self->_suspended || self->_configurationActive ||
                    generation != self->_actionGeneration ||
                    NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != application) return;
                if (self.onOpenPanel) self.onOpenPanel();
            });
        }
    }
    // The active tap is installed ahead of the passive tap. Swallowed keys
    // never reach that tap, but must still break an unfinished copy pair.
    if (active && consumed && type == kCGEventKeyDown && bawan::isPassiveCopy(_bindings[selectionIndex])) {
        _gestures[selectionIndex].cancel();
    }
    if (active && _awaitingCopyRelease && type == kCGEventKeyUp && key == _copyReleaseKey) {
        _awaitingCopyRelease = NO;
        [_selectionReader readSelection];
    }
    if (active && type == kCGEventKeyUp && consumed) {
        __weak ShortcutMonitor *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
    }
    return active && consumed;
}

- (void)dealloc {
    [self stop];
}

@end
