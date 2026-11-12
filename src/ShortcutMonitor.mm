#import "ShortcutMonitor.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>

#include <array>

namespace {
constexpr int64_t copyEventTag = 0x4c6f7265436f7079; // "LoreCopy"
constexpr unsigned selectionIndex = static_cast<unsigned>(lore::ShortcutAction::TranslateSelection);
constexpr unsigned panelIndex = static_cast<unsigned>(lore::ShortcutAction::OpenPanel);
}

@interface ShortcutMonitor () {
    ShortcutPreferences *_preferences;
    lore::ShortcutBindings _bindings;
    std::array<lore::ShortcutGesture, 2> _gestures;
    std::array<ShortcutAvailability, 2> _availability;
    // Keep ownership through configuration changes, including modifier release
    // before key-up. A draining tap does not reserve any new key presses.
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
    BOOL _settingsActive;
    NSInteger _firstChangeCount;
    pid_t _firstApplication;
    NSInteger _pendingChangeCount;
    pid_t _pendingApplication;
    BOOL _awaitingCopyRelease;
    std::uint16_t _copyReleaseKey;
    pid_t _copyReleaseApplication;
    NSUInteger _generation;
    NSUInteger _copyReleaseGeneration;
    NSMutableArray<id> *_workspaceObservers;
    id _activationObserver;
    id _preferencesObserver;
}
- (BOOL)handleEventType:(CGEventType)type event:(CGEventRef)event active:(BOOL)active;
- (void)cancelPending;
- (void)configureGestures;
- (void)applyPreferences;
- (BOOL)installTapActive:(BOOL)active;
- (void)removeTapActive:(BOOL)active;
- (void)beginReadingCopyFromApplication:(pid_t)application changeCount:(NSInteger)changeCount;
- (void)sendCopyForGeneration:(NSUInteger)generation application:(pid_t)application;
- (void)checkCopyForGeneration:(NSUInteger)generation deadline:(NSTimeInterval)deadline;
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
    self = [super init];
    if (!self) return nil;
    _preferences = preferences;
    _bindings = preferences.bindings;
    _availability.fill(ShortcutAvailabilityOff);
    [self configureGestures];
    return self;
}

- (void)configureGestures {
    ++_gestureRevision;
    for (unsigned i = 0; i < _gestures.size(); ++i) {
        _gestures[i].configure(_bindings[i], !(i == selectionIndex && lore::isPassiveCopy(_bindings[i])));
    }
}

- (void)cancelPending {
    ++_generation;
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
    _activationObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:NSApplicationDidBecomeActiveNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *) { [weakSelf refresh]; }];
    _preferencesObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:LoreShortcutsDidChangeNotification object:_preferences
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
    if (_activationObserver) [NSNotificationCenter.defaultCenter removeObserver:_activationObserver];
    if (_preferencesObserver) [NSNotificationCenter.defaultCenter removeObserver:_preferencesObserver];
    _activationObserver = nil;
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

- (BOOL)settingsActive { return _settingsActive; }
- (void)setSettingsActive:(BOOL)active {
    if (_settingsActive == active) return;
    _settingsActive = active;
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
        if (i == selectionIndex && lore::isPassiveCopy(_bindings[i])) wantsPassive = true;
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
        // Permission loss prevents further draining; do not reserve a future press.
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
            const bool passive = i == selectionIndex && lore::isPassiveCopy(_bindings[i]);
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

- (ShortcutAvailability)availabilityForAction:(lore::ShortcutAction)action {
    return _availability[static_cast<unsigned>(action)];
}

- (void)requestPermissionForAction:(lore::ShortcutAction)action {
    const auto binding = [_preferences bindingForAction:action];
    NSString *pane = nil;
    if (action == lore::ShortcutAction::TranslateSelection && lore::isPassiveCopy(binding)) {
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
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == copyEventTag) return NO;
    if (type != kCGEventKeyDown && type != kCGEventKeyUp && type != kCGEventFlagsChanged) return NO;

    const auto key = static_cast<std::uint16_t>(CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode));
    const bool repeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
    const bool owned = active && key < _swallowed.size() && _swallowed[key];
    bool consumed = owned && (type == kCGEventKeyDown || type == kCGEventKeyUp);
    if (active && type == kCGEventKeyUp && key < _swallowed.size()) _swallowed[key] = false;
    if (_suspended) {
        if (active && type == kCGEventKeyUp) {
            __weak ShortcutMonitor *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
        }
        return consumed;
    }

    const pid_t application = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    const lore::ShortcutEvent input = {
        type == kCGEventKeyDown ? lore::ShortcutEvent::Kind::KeyDown :
            type == kCGEventKeyUp ? lore::ShortcutEvent::Kind::KeyUp : lore::ShortcutEvent::Kind::FlagsChanged,
        key, ShortcutModifiersFromFlags(static_cast<NSEventModifierFlags>(CGEventGetFlags(event)), key),
        repeat, application, CGEventGetTimestamp(event)
    };
    if (_awaitingCopyRelease && type == kCGEventKeyDown && key != _copyReleaseKey) {
        [self cancelPending];
    }
    for (unsigned i = 0; i < _bindings.size(); ++i) {
        const bool passive = i == selectionIndex && lore::isPassiveCopy(_bindings[i]);
        if (!_bindings[i].enabled || passive == static_cast<bool>(active)) continue;
        // A held key from an old configuration must not become a new gesture.
        if (owned && type == kCGEventKeyDown && _swallowedRevision[key] != _gestureRevision) continue;
        const auto result = _gestures[i].handle(input);
        consumed |= result.consumed;
        if (active && result.consumed && type == kCGEventKeyDown && key < _swallowed.size()) {
            _swallowed[key] = true;
            _swallowedRevision[key] = _gestureRevision;
        }
        if (_settingsActive) continue;
        if (result.firstPress) {
            ++_generation;
            _awaitingCopyRelease = NO;
            if (passive) {
                _firstChangeCount = NSPasteboard.generalPasteboard.changeCount;
                _firstApplication = application;
            }
        }
        if (!result.triggered) continue;
        if (i == selectionIndex) {
            if (passive) {
                [self beginReadingCopyFromApplication:_firstApplication changeCount:_firstChangeCount];
            } else {
                _copyReleaseGeneration = ++_generation;
                _awaitingCopyRelease = YES;
                _copyReleaseKey = key;
                _copyReleaseApplication = application;
            }
        } else if (i == panelIndex) {
            const NSUInteger generation = ++_generation;
            __weak ShortcutMonitor *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                ShortcutMonitor *self = weakSelf;
                if (!self || !self->_started || self->_suspended || self->_settingsActive ||
                    generation != self->_generation ||
                    NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != application) return;
                if (self.onOpenPanel) self.onOpenPanel();
            });
        }
    }
    // The active tap is installed ahead of the passive tap. Swallowed keys
    // never reach that tap, but must still break an unfinished copy pair.
    if (active && consumed && type == kCGEventKeyDown && lore::isPassiveCopy(_bindings[selectionIndex])) {
        _gestures[selectionIndex].cancel();
    }
    if (active && _awaitingCopyRelease && type == kCGEventKeyUp && key == _copyReleaseKey) {
        _awaitingCopyRelease = NO;
        const NSUInteger generation = _copyReleaseGeneration;
        const pid_t source = _copyReleaseApplication;
        __weak ShortcutMonitor *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf sendCopyForGeneration:generation application:source]; });
    }
    if (active && type == kCGEventKeyUp && consumed) {
        __weak ShortcutMonitor *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
    }
    return active && consumed;
}

- (void)sendCopyForGeneration:(NSUInteger)generation application:(pid_t)application {
    if (!_started || _suspended || _settingsActive || generation != _generation ||
        NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != application) return;
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    CGEventRef down = CGEventCreateKeyboardEvent(source, 8, true);
    CGEventRef up = CGEventCreateKeyboardEvent(source, 8, false);
    if (source) CFRelease(source);
    if (!down || !up) {
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        if (self.onProblem) self.onProblem(@"Unable to copy the selected text. Type or paste the source text instead.");
        return;
    }
    CGEventSetFlags(down, kCGEventFlagMaskCommand);
    CGEventSetFlags(up, kCGEventFlagMaskCommand);
    CGEventSetIntegerValueField(down, kCGEventSourceUserData, copyEventTag);
    CGEventSetIntegerValueField(up, kCGEventSourceUserData, copyEventTag);
    const NSInteger changeCount = NSPasteboard.generalPasteboard.changeCount;
    CGEventPost(kCGSessionEventTap, down);
    CGEventPost(kCGSessionEventTap, up);
    CFRelease(down);
    CFRelease(up);
    [self beginReadingCopyFromApplication:application changeCount:changeCount];
}

- (void)beginReadingCopyFromApplication:(pid_t)application changeCount:(NSInteger)changeCount {
    _pendingChangeCount = changeCount;
    _pendingApplication = application;
    const NSUInteger generation = ++_generation;
    const NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 0.8;
    // Give the foreground app time to process the actual or synthesized copy.
    __weak ShortcutMonitor *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [weakSelf checkCopyForGeneration:generation deadline:deadline];
    });
}

- (void)checkCopyForGeneration:(NSUInteger)generation deadline:(NSTimeInterval)deadline {
    if (!_started || _suspended || _settingsActive || generation != _generation) return;
    if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != _pendingApplication) return;
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 150400
    if (@available(macOS 15.4, *)) {
        if (pasteboard.accessBehavior == NSPasteboardAccessBehaviorAlwaysDeny) {
            ++_generation;
            if (self.onProblem) self.onProblem(@"Clipboard access was denied. Allow Lore to read the clipboard in System Settings, or type or paste text.");
            return;
        }
    }
#endif
    if (pasteboard.changeCount != _pendingChangeCount) {
        NSString *text = [pasteboard stringForType:NSPasteboardTypeString];
        if (generation != _generation || !_started || _suspended || _settingsActive ||
            NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != _pendingApplication) return;
        ++_generation;
        if ([text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {
            if (self.onText) self.onText(text);
        } else if (self.onProblem) {
            self.onProblem(@"Unable to read copied text. Select text and try translating again, or type or paste text.");
        }
        return;
    }
    if (NSProcessInfo.processInfo.systemUptime >= deadline) {
        ++_generation;
        if (self.onProblem) self.onProblem(@"No updated copy was detected. Select text and try translating again, or type or paste text.");
        return;
    }
    __weak ShortcutMonitor *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [weakSelf checkCopyForGeneration:generation deadline:deadline];
    });
}

- (void)dealloc {
    // The application stops monitoring before releasing its owner. Removing
    // observers here also makes short-lived test instances safe to release.
    [self stop];
}

@end
