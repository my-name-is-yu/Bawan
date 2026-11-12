#import "ShortcutMonitor.h"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include "CopyGesture.h"

@interface ShortcutMonitor () {
    CFMachPortRef _tap;
    CFRunLoopSourceRef _source;
    lore::CopyGesture _gesture;
    BOOL _enabled;
    NSInteger _firstChangeCount;
    pid_t _sourceApplication;
    NSInteger _pendingChangeCount;
    pid_t _pendingApplication;
    NSUInteger _readGeneration;
    NSMutableArray<id> *_workspaceObservers;
    id _activationObserver;
}
- (void)handleEventType:(CGEventType)type event:(CGEventRef)event;
- (void)removeTap;
- (BOOL)installTapRequestingPermission:(BOOL)request reportFailure:(BOOL)report;
- (void)checkCopyForGeneration:(NSUInteger)generation deadline:(NSTimeInterval)deadline;
@end

static CGEventRef observeKey(CGEventTapProxy, CGEventType type, CGEventRef event, void *context) {
    @autoreleasepool {
        [(__bridge ShortcutMonitor *)context handleEventType:type event:event];
    }
    return event;
}

@implementation ShortcutMonitor

- (BOOL)isListening {
    return _tap != nullptr && CGEventTapIsEnabled(_tap);
}

- (BOOL)startRequestingPermission:(BOOL)request {
    NSAssert(NSThread.isMainThread, @"Shortcut monitoring runs on the main thread");
    [self stop];
    _enabled = YES;
    _workspaceObservers = [NSMutableArray array];
    NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
    __weak ShortcutMonitor *weakSelf = self;
    [_workspaceObservers addObject:[center addObserverForName:NSWorkspaceDidActivateApplicationNotification
                                                       object:nil queue:NSOperationQueue.mainQueue
                                                   usingBlock:^(NSNotification *note) {
        ShortcutMonitor *self = weakSelf;
        if (!self) return;
        self->_gesture.reset();
        ++self->_readGeneration;
    }]];
    [_workspaceObservers addObject:[center addObserverForName:NSWorkspaceWillSleepNotification
                                                       object:nil queue:NSOperationQueue.mainQueue
                                                   usingBlock:^(NSNotification *note) {
        ShortcutMonitor *self = weakSelf;
        if (!self) return;
        ++self->_readGeneration;
        self->_gesture.reset();
        [self removeTap];
    }]];
    [_workspaceObservers addObject:[center addObserverForName:NSWorkspaceDidWakeNotification
                                                       object:nil queue:NSOperationQueue.mainQueue
                                                   usingBlock:^(NSNotification *note) {
        ShortcutMonitor *self = weakSelf;
        if (self && self->_enabled) {
            [self removeTap];
            [self installTapRequestingPermission:NO reportFailure:YES];
        }
    }]];
    _activationObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:NSApplicationDidBecomeActiveNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        ShortcutMonitor *self = weakSelf;
        if (self && self->_enabled && !self.isListening) {
            [self removeTap];
            [self installTapRequestingPermission:NO reportFailure:NO];
        }
    }];
    return [self installTapRequestingPermission:request reportFailure:YES];
}

- (BOOL)installTapRequestingPermission:(BOOL)request reportFailure:(BOOL)report {
    if (!CGPreflightListenEventAccess() &&
        !(request && CGRequestListenEventAccess())) {
        if (report && self.onProblem) {
            self.onProblem(@"⌘Cを2回押して翻訳するには、システム設定 → プライバシーとセキュリティ → 入力監視でLoreを許可してください。手入力での翻訳は使えます。");
        }
        return NO;
    }
    const CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
    _tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                           kCGEventTapOptionListenOnly, mask, observeKey,
                           (__bridge void *)self);
    if (_tap) _source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
    if (!_tap || !_source) {
        [self removeTap];
        if (report && self.onProblem) {
            self.onProblem(@"キーの監視を開始できませんでした。入力監視の許可を確認し、設定から再度有効にしてください。");
        }
        return NO;
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
    CGEventTapEnable(_tap, true);
    return YES;
}

- (void)removeTap {
    if (_source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
        CFRunLoopSourceInvalidate(_source);
        CFRelease(_source);
        _source = nullptr;
    }
    if (_tap) {
        CGEventTapEnable(_tap, false);
        CFMachPortInvalidate(_tap);
        CFRelease(_tap);
        _tap = nullptr;
    }
}

- (void)stop {
    NSAssert(NSThread.isMainThread, @"Shortcut monitoring runs on the main thread");
    _enabled = NO;
    ++_readGeneration;
    _gesture.reset();
    [self removeTap];
    NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
    for (id observer in _workspaceObservers) [center removeObserver:observer];
    _workspaceObservers = nil;
    if (_activationObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:_activationObserver];
        _activationObserver = nil;
    }
}

- (void)handleEventType:(CGEventType)type event:(CGEventRef)event {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        _gesture.reset();
        ++_readGeneration;
        if (_tap && CGPreflightListenEventAccess()) {
            CGEventTapEnable(_tap, true);
        } else if (self.onProblem) {
            self.onProblem(@"キーの監視が停止しました。システム設定の入力監視を確認してください。手入力での翻訳は使えます。");
        }
        return;
    }
    if (!_enabled || (type != kCGEventKeyDown && type != kCGEventKeyUp)) return;
    const CGEventFlags flags = CGEventGetFlags(event);
    const pid_t application = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    const auto result = _gesture.handle({
        type == kCGEventKeyDown,
        static_cast<std::uint16_t>(CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode)),
        (flags & kCGEventFlagMaskCommand) != 0,
        (flags & (kCGEventFlagMaskShift | kCGEventFlagMaskControl |
                  kCGEventFlagMaskAlternate | kCGEventFlagMaskSecondaryFn)) != 0,
        CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0,
        application,
        CGEventGetTimestamp(event)
    });
    if (result == lore::CopyGesture::Result::FirstCopy) {
        _firstChangeCount = NSPasteboard.generalPasteboard.changeCount;
        _sourceApplication = application;
    } else if (result == lore::CopyGesture::Result::DoubleCopy) {
        _pendingChangeCount = _firstChangeCount;
        _pendingApplication = _sourceApplication;
        const NSUInteger generation = ++_readGeneration;
        const NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 0.8;
        // Let the source app process the second copy before showing our panel.
        __weak ShortcutMonitor *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            [weakSelf checkCopyForGeneration:generation deadline:deadline];
        });
    }
}

- (void)checkCopyForGeneration:(NSUInteger)generation deadline:(NSTimeInterval)deadline {
    if (!_enabled || generation != _readGeneration) return;
    if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != _pendingApplication) return;

    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 150400
    if (@available(macOS 15.4, *)) {
        if (pasteboard.accessBehavior == NSPasteboardAccessBehaviorAlwaysDeny) {
            ++_readGeneration;
            if (self.onProblem) self.onProblem(@"クリップボードの読み取りが拒否されています。システム設定でLoreのクリップボード利用を許可するか、原文を手入力してください。");
            return;
        }
    }
#endif
    if (pasteboard.changeCount != _pendingChangeCount) {
        // Never compare the string with the previous translation: copying the
        // same selected passage again is a valid new request.
        NSString *text = [pasteboard stringForType:NSPasteboardTypeString];
        if (generation != _readGeneration || !_enabled) return;
        ++_readGeneration;
        if (text.length && [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {
            if (self.onText) self.onText(text);
        } else if (self.onProblem) {
            self.onProblem(@"コピーしたテキストを読み取れませんでした。文章を選択して再度⌘Cを2回押すか、原文を手入力してください。");
        }
        return;
    }
    if (NSProcessInfo.processInfo.systemUptime >= deadline) {
        ++_readGeneration;
        if (self.onProblem) self.onProblem(@"コピーの更新を確認できませんでした。文章を選択して再度⌘Cを2回押してください。");
        return;
    }
    __weak ShortcutMonitor *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        [weakSelf checkCopyForGeneration:generation deadline:deadline];
    });
}

- (void)dealloc {
    [self stop];
}

@end
