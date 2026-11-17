#import "SelectionReader.h"
#import "SystemKeyboardLayout.h"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

bool PostCopyEvents(const bawan::KeyboardLayout& layout, void (^post)(CGEventRef)) {
    const auto key = layout.copyKey();
    if (!key) return false;
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    if (!source) return false;
    CGEventRef down = CGEventCreateKeyboardEvent(source, *key, true);
    CGEventRef up = CGEventCreateKeyboardEvent(source, *key, false);
    if (source) CFRelease(source);
    if (!down || !up) {
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        return false;
    }
    const CGEventRef events[] = {down, up};
    for (CGEventRef event : events) {
        CGEventSetFlags(event, kCGEventFlagMaskCommand);
        CGEventSetIntegerValueField(event, kCGEventSourceUserData, bawan::selectionCopyEventTag);
        post(event);
        CFRelease(event);
    }
    return true;
}

@interface SystemSelectionEnvironment : NSObject <SelectionReaderEnvironment>
@end

@implementation SystemSelectionEnvironment
- (pid_t)frontmostApplication { return NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier; }
- (NSInteger)pasteboardChangeCount { return NSPasteboard.generalPasteboard.changeCount; }
- (NSString *)copiedText { return [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString]; }
- (BOOL)clipboardAccessDenied {
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 150400
    if (@available(macOS 15.4, *)) {
        return NSPasteboard.generalPasteboard.accessBehavior == NSPasteboardAccessBehaviorAlwaysDeny;
    }
#endif
    return NO;
}
- (BOOL)sendCopy {
    return PostCopyEvents(CurrentKeyboardLayout(), ^(CGEventRef event) { CGEventPost(kCGSessionEventTap, event); });
}
- (NSTimeInterval)uptime { return NSProcessInfo.processInfo.systemUptime; }
- (void)scheduleAfter:(NSTimeInterval)delay perform:(void (^)(void))callback {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), callback);
}
@end

@interface SelectionCopySession : NSObject
@property(nonatomic) pid_t application;
@property(nonatomic) NSInteger changeCount;
@property(nonatomic) BOOL passive;
@property(nonatomic) BOOL reading;
@property(nonatomic) NSTimeInterval deadline;
@end
@implementation SelectionCopySession
@end

@interface SelectionReader () {
    id<SelectionReaderEnvironment> _environment;
    SelectionCopySession *_session;
}
- (BOOL)isCurrentSession:(SelectionCopySession *)session;
- (void)checkCopy:(SelectionCopySession *)session;
- (void)scheduleCheck:(SelectionCopySession *)session after:(NSTimeInterval)delay;
- (void)finishSession:(SelectionCopySession *)session text:(nullable NSString *)text problem:(nullable NSString *)problem;
@end

@implementation SelectionReader
- (instancetype)init {
    return [self initWithEnvironment:[SystemSelectionEnvironment new]];
}
- (instancetype)initWithEnvironment:(id<SelectionReaderEnvironment>)environment {
    self = [super init];
    if (self) _environment = environment;
    return self;
}
- (void)cancel { _session = nil; }
- (void)beginCopyFromApplication:(pid_t)application passive:(BOOL)passive {
    SelectionCopySession *session = [SelectionCopySession new];
    session.application = application;
    session.passive = passive;
    _session = session;
    if (passive) session.changeCount = [_environment pasteboardChangeCount];
}
- (BOOL)isCurrentSession:(SelectionCopySession *)session {
    if (_session != session) return NO;
    const pid_t application = [_environment frontmostApplication];
    if (_session != session) return NO;
    if (application != session.application) {
        [self cancel];
        return NO;
    }
    return YES;
}
- (void)readSelection {
    SelectionCopySession *session = _session;
    if (!session || session.reading || ![self isCurrentSession:session]) return;
    session.reading = YES;
    if (session.passive) {
        session.deadline = [_environment uptime] + 0.8;
        [self scheduleCheck:session after:0.06];
        return;
    }
    __weak SelectionReader *weakSelf = self;
    [_environment scheduleAfter:0 perform:^{
        SelectionReader *self = weakSelf;
        if (!self || ![self isCurrentSession:session]) return;
        session.changeCount = [self->_environment pasteboardChangeCount];
        if (![self isCurrentSession:session]) return;
        if (![self->_environment sendCopy]) {
            [self finishSession:session text:nil problem:@"Unable to copy the selected text. Type or paste the source text instead."];
            return;
        }
        if (![self isCurrentSession:session]) return;
        session.deadline = [self->_environment uptime] + 0.8;
        [self scheduleCheck:session after:0.06];
    }];
}
- (void)scheduleCheck:(SelectionCopySession *)session after:(NSTimeInterval)delay {
    __weak SelectionReader *weakSelf = self;
    [_environment scheduleAfter:delay perform:^{ [weakSelf checkCopy:session]; }];
}
- (void)checkCopy:(SelectionCopySession *)session {
    if (![self isCurrentSession:session]) return;
    if ([_environment clipboardAccessDenied]) {
        [self finishSession:session text:nil problem:@"Clipboard access was denied. Allow Bawan to read the clipboard in System Settings, or type or paste text."];
        return;
    }
    if ([_environment pasteboardChangeCount] != session.changeCount) {
        NSString *text = [_environment copiedText];
        NSString *problem = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length ? nil :
            @"Unable to read copied text. Select text and try translating again, or type or paste text.";
        [self finishSession:session text:text problem:problem];
        return;
    }
    if ([_environment uptime] >= session.deadline) {
        [self finishSession:session text:nil problem:@"No updated copy was detected. Select text and try translating again, or type or paste text."];
        return;
    }
    [self scheduleCheck:session after:0.02];
}
- (void)finishSession:(SelectionCopySession *)session text:(NSString *)text problem:(NSString *)problem {
    // Reading promised pasteboard data can reenter the app and replace/cancel this session.
    if (![self isCurrentSession:session]) return;
    [self cancel];
    if (problem) {
        if (self.onProblem) self.onProblem(problem);
    } else if (self.onText) self.onText(text);
}
@end
