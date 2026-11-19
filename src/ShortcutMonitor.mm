#import "ShortcutMonitor.h"
#import "SelectionReader.h"
#include "ShortcutMonitorState.h"
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
    bawan::ShortcutMonitorState _state;
    bawan::ShortcutKeyOwnership _keys;
    bool _passiveSelection;
    __weak NSTextView *_selectionTrialView;
    CFMachPortRef _passiveTap;
    CFMachPortRef _activeTap;
    CFRunLoopSourceRef _passiveSource;
    CFRunLoopSourceRef _activeSource;
    NSUInteger _actionGeneration;
    NSMutableArray<id> *_workspaceObservers;
    id _preferencesObserver;
}
- (BOOL)handleEventType:(CGEventType)type event:(CGEventRef)event active:(BOOL)active;
- (void)cancelPending;
- (void)configureGestures;
- (void)applyPreferences;
- (void)loadBindings;
- (NSTextView *)activeSelectionTrialView;
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
    _availability.fill(ShortcutAvailabilityOff);
    [self loadBindings];
    return self;
}

- (void)configureGestures {
    _keys.reconfigure();
    for (unsigned i = 0; i < _gestures.size(); ++i) {
        _gestures[i].configure(_bindings[i], !(i == selectionIndex && _passiveSelection));
    }
}

- (void)cancelPending {
    ++_actionGeneration;
    [_selectionReader cancel];
    _keys.cancelCopy();
    for (auto &gesture : _gestures) gesture.cancel();
}

- (void)loadBindings {
    _bindings = _preferences.bindings;
    _passiveSelection = bawan::isPassiveCopy(_bindings[selectionIndex]);
    [self configureGestures];
}

- (void)applyPreferences {
    [self cancelPending];
    [self loadBindings];
    [self refresh];
}

- (void)start {
    NSAssert(NSThread.isMainThread, @"Shortcut monitoring runs on the main thread");
    if (!_state.transition(bawan::ShortcutMonitorState::Transition::Start)) { [self refresh]; return; }
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
        self->_state.transition(bawan::ShortcutMonitorState::Transition::Sleep);
        [self cancelPending];
        self->_keys.reset();
        [self removeTapActive:NO];
        [self removeTapActive:YES];
        [self configureGestures];
    }]];
    [_workspaceObservers addObject:[workspace addObserverForName:NSWorkspaceDidWakeNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *) {
        ShortcutMonitor *self = weakSelf;
        if (!self) return;
        self->_state.transition(bawan::ShortcutMonitorState::Transition::Wake);
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
    _state.transition(bawan::ShortcutMonitorState::Transition::Stop);
    [self cancelPending];
    _keys.reset();
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

- (BOOL)suspended { return _state.suspended(); }
- (void)setSuspended:(BOOL)suspended {
    if (!_state.transition(suspended ? bawan::ShortcutMonitorState::Transition::Suspend :
        bawan::ShortcutMonitorState::Transition::Resume)) return;
    [self cancelPending];
    [self configureGestures];
    [self refresh];
}

- (BOOL)configurationActive { return _state.configurationActive(); }
- (void)setConfigurationActive:(BOOL)active {
    if (!_state.transition(active ? bawan::ShortcutMonitorState::Transition::EnterConfiguration :
        bawan::ShortcutMonitorState::Transition::LeaveConfiguration)) return;
    [self cancelPending];
    [self configureGestures];
    [self refresh];
}

- (NSTextView *)selectionTrialView { return _selectionTrialView; }
- (void)setSelectionTrialView:(NSTextView *)view {
    if (_selectionTrialView == view) return;
    _selectionTrialView = view;
    [self cancelPending];
    [self configureGestures];
}

- (NSTextView *)activeSelectionTrialView {
    if (_state.mode() != bawan::ShortcutMonitorState::Mode::Configuration) return nil;
    NSTextView *view = _selectionTrialView;
    NSWindow *window = view.window;
    const NSUInteger length = view.string.length;
    if (!view || view.hiddenOrHasHiddenAncestor || !window.isKeyWindow || !window.visible ||
        window.firstResponder != view || !length ||
        !NSEqualRanges(view.selectedRange, NSMakeRange(0, length)) || !_bindings[selectionIndex].enabled ||
        [self availabilityForAction:bawan::ShortcutAction::TranslateSelection] != ShortcutAvailabilityAvailable) return nil;
    return view;
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
    const bool passiveTapInterrupted = hadPassiveTap && !CGEventTapIsEnabled(_passiveTap);
    const bool activeTapInterrupted = hadActiveTap && !CGEventTapIsEnabled(_activeTap);
    if (!hadActiveTap || activeTapInterrupted) {
        // Key-up may have happened while a timed-out tap was disabled. Keep
        // swallowing held keys, but never swallow a future unrelated press.
        _keys.reconcile([](unsigned key) {
            return CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, key);
        });
    }
    bool wantsPassive = false;
    bool wantsActive = false;
    for (unsigned i = 0; i < _bindings.size(); ++i) {
        if (!_bindings[i].enabled) continue;
        if (i == selectionIndex && _passiveSelection) wantsPassive = true;
        else wantsActive = true;
    }
    const bool observing = _state.observing();
    if (observing && wantsPassive && inputAllowed) [self installTapActive:NO];
    else [self removeTapActive:NO];
    if (_state.awake() && accessibilityAllowed && ((observing && wantsActive) || _keys.draining())) {
        [self installTapActive:YES];
    } else {
        [self removeTapActive:YES];
        if (!accessibilityAllowed) _keys.reset();
    }
    // A tap can resume in place after missing a release. Discard its
    // gesture state while preserving ownership of keys still held.
    if (passiveTapInterrupted || activeTapInterrupted ||
        hadPassiveTap != (_passiveTap != nullptr) || hadActiveTap != (_activeTap != nullptr)) {
        [self cancelPending];
        [self configureGestures];
    }
    bool changed = false;
    for (unsigned i = 0; i < _bindings.size(); ++i) {
        ShortcutAvailability state = ShortcutAvailabilityOff;
        if (_state.started() && _bindings[i].enabled) {
            const bool passive = i == selectionIndex && _passiveSelection;
            if (passive && !inputAllowed) state = ShortcutAvailabilityNeedsInputMonitoring;
            else if (!passive && !accessibilityAllowed) state = ShortcutAvailabilityNeedsAccessibility;
            else if (!observing) state = _availability[i];
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
    NSString *pane = nil;
    if (action == bawan::ShortcutAction::TranslateSelection && _passiveSelection) {
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
    if (!_state.awake() || !event) return NO;
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == bawan::selectionCopyEventTag) return NO;
    if (type != kCGEventKeyDown && type != kCGEventKeyUp && type != kCGEventFlagsChanged) return NO;

    const auto key = static_cast<std::uint16_t>(CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode));
    const bool repeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
    const auto kind = type == kCGEventKeyDown ? bawan::ShortcutEvent::Kind::KeyDown :
        type == kCGEventKeyUp ? bawan::ShortcutEvent::Kind::KeyUp : bawan::ShortcutEvent::Kind::FlagsChanged;
    const auto ownership = active ? _keys.handle(kind, key) : bawan::ShortcutKeyOwnership::Result{};
    bool consumed = ownership.consumed;
    const auto modifiers = ShortcutModifiersFromFlags(static_cast<NSEventModifierFlags>(CGEventGetFlags(event)), key);
    // A nonactivating panel can own keyboard input while another app stays frontmost.
    NSWindow *keyWindow = NSApp.keyWindow;
    const bool nativeCommand = keyWindow.isKeyWindow && keyWindow.visible &&
        bawan::isNativeWindowShortcut(key, modifiers);
    NSTextView *trialView = [self activeSelectionTrialView];
    if ((!_state.running() || nativeCommand) && !trialView) {
        if (_state.configurationActive() || nativeCommand) {
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
        kind, key, modifiers,
        repeat, application, CGEventGetTimestamp(event)
    };
    if (ownership.copyInterrupted) {
        [self cancelPending];
    }
    for (unsigned i = 0; i < _bindings.size(); ++i) {
        if (trialView && i != selectionIndex) continue;
        const bool passive = i == selectionIndex && _passiveSelection;
        if (!_bindings[i].enabled || passive == static_cast<bool>(active)) continue;
        if (ownership.drainingDown) continue;
        const auto result = _gestures[i].handle(input);
        consumed |= result.consumed;
        if (active && result.consumed && type == kCGEventKeyDown) _keys.capture(key);
        if (result.firstPress) {
            ++_actionGeneration;
            [_selectionReader cancel];
            _keys.cancelCopy();
            if (passive && !trialView) [_selectionReader beginCopyFromApplication:application passive:YES];
        }
        if (!result.triggered) continue;
        if (i == selectionIndex) {
            if (trialView) {
                const NSUInteger generation = ++_actionGeneration;
                const NSRange selected = trialView.selectedRange;
                NSString *source = [trialView.string copy];
                __weak ShortcutMonitor *weakSelf = self;
                __weak NSTextView *weakView = trialView;
                dispatch_async(dispatch_get_main_queue(), ^{
                    ShortcutMonitor *self = weakSelf;
                    NSTextView *view = weakView;
                    if (!self || !view || generation != self->_actionGeneration ||
                        [self activeSelectionTrialView] != view ||
                        !NSEqualRanges(view.selectedRange, selected) || ![view.string isEqualToString:source]) return;
                    if (self.onSelectionTrial) self.onSelectionTrial(source);
                });
            } else if (passive) {
                [_selectionReader readSelection];
            } else {
                ++_actionGeneration;
                [_selectionReader beginCopyFromApplication:application passive:NO];
                _keys.awaitCopyRelease(key);
            }
        } else if (i == panelIndex) {
            const NSUInteger generation = ++_actionGeneration;
            [_selectionReader cancel];
            _keys.cancelCopy();
            __weak ShortcutMonitor *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                ShortcutMonitor *self = weakSelf;
                if (!self || !self->_state.running() ||
                    generation != self->_actionGeneration ||
                    NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != application) return;
                if (self.onOpenPanel) self.onOpenPanel();
            });
        }
    }
    // The active tap is installed ahead of the passive tap. Swallowed keys
    // never reach that tap, but must still break an unfinished copy pair.
    if (active && consumed && type == kCGEventKeyDown && _passiveSelection) {
        _gestures[selectionIndex].cancel();
    }
    if (ownership.copyReleased) {
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
