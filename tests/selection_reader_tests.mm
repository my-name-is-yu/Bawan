#import "SelectionReader.h"

#include <cstdlib>
#include <iostream>

static void require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

@interface ScheduledSelectionCallback : NSObject
@property(nonatomic) NSTimeInterval time;
@property(nonatomic, copy) void (^perform)(void);
@end
@implementation ScheduledSelectionCallback
@end

@interface FakeSelectionEnvironment : NSObject <SelectionReaderEnvironment>
@property(nonatomic) pid_t application;
@property(nonatomic) NSInteger changeCount;
@property(nonatomic, copy) NSString *text;
@property(nonatomic) BOOL denied;
@property(nonatomic) BOOL copySucceeds;
@property(nonatomic) NSTimeInterval now;
@property(nonatomic) unsigned sends;
@property(nonatomic) unsigned reads;
@property(nonatomic, copy) void (^onRead)(void);
@property(nonatomic, copy) void (^onSend)(void);
@property(nonatomic, copy) void (^onChangeCount)(void);
- (void)runUntil:(NSTimeInterval)time;
@end

@implementation FakeSelectionEnvironment {
    NSMutableArray<ScheduledSelectionCallback *> *_callbacks;
}
- (instancetype)init {
    self = [super init];
    if (self) {
        _application = 42;
        _changeCount = 7;
        _copySucceeds = YES;
        _callbacks = [NSMutableArray array];
    }
    return self;
}
- (pid_t)frontmostApplication { return self.application; }
- (NSInteger)pasteboardChangeCount {
    NSInteger changeCount = self.changeCount;
    void (^onChangeCount)(void) = self.onChangeCount;
    self.onChangeCount = nil;
    if (onChangeCount) onChangeCount();
    return changeCount;
}
- (NSString *)copiedText {
    ++_reads;
    NSString *text = self.text;
    void (^onRead)(void) = self.onRead;
    self.onRead = nil;
    if (onRead) onRead();
    return text;
}
- (BOOL)clipboardAccessDenied { return self.denied; }
- (BOOL)sendCopy {
    ++_sends;
    if (self.onSend) self.onSend();
    return self.copySucceeds;
}
- (NSTimeInterval)uptime { return self.now; }
- (void)scheduleAfter:(NSTimeInterval)delay perform:(void (^)(void))callback {
    ScheduledSelectionCallback *scheduled = [ScheduledSelectionCallback new];
    scheduled.time = self.now + delay;
    scheduled.perform = callback;
    [_callbacks addObject:scheduled];
}
- (void)runUntil:(NSTimeInterval)time {
    require(time >= self.now, "fake clock advances monotonically");
    for (unsigned count = 0; count < 1000; ++count) {
        ScheduledSelectionCallback *next = nil;
        for (ScheduledSelectionCallback *candidate in _callbacks) {
            if (candidate.time <= time && (!next || candidate.time < next.time)) next = candidate;
        }
        if (!next) {
            self.now = time;
            return;
        }
        self.now = next.time;
        [_callbacks removeObjectIdenticalTo:next];
        next.perform();
    }
    require(false, "reader does not schedule unbounded work without advancing time");
}
@end

struct Fixture {
    FakeSelectionEnvironment *environment = [FakeSelectionEnvironment new];
    SelectionReader *reader = [[SelectionReader alloc] initWithEnvironment:environment];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    NSMutableArray<NSString *> *problems = [NSMutableArray array];
    Fixture() {
        NSMutableArray<NSString *> *receivedTexts = texts;
        NSMutableArray<NSString *> *receivedProblems = problems;
        reader.onText = ^(NSString *text) { [receivedTexts addObject:text]; };
        reader.onProblem = ^(NSString *message) { [receivedProblems addObject:message]; };
    }
    void begin(BOOL passive = YES) {
        [reader beginCopyFromApplication:environment.application passive:passive];
    }
    void copy(NSString *text) {
        environment.text = text;
        ++environment.changeCount;
    }
    bool quiet() const { return texts.count == 0 && problems.count == 0; }
    void requireText(NSString *text, const char *message) const {
        require(texts.count == 1 && [texts.firstObject isEqualToString:text] && problems.count == 0, message);
    }
    void requireProblem(const char *message) const {
        require(texts.count == 0 && problems.count == 1 && problems.firstObject.length != 0, message);
    }
};

static void testPassiveCopy() {
    Fixture f;
    f.begin();
    f.copy(@"  first physical copy\n");
    // The second physical Cmd-C need not update the clipboard again.
    [f.reader readSelection];
    [f.environment runUntil:0.059];
    require(f.quiet() && f.environment.reads == 0, "passive copy waits for the foreground application");
    [f.environment runUntil:0.06];
    f.requireText(@"  first physical copy\n", "passive copy uses the first-press baseline and preserves text whitespace");
    [f.environment runUntil:1];
    require(f.texts.count == 1 && f.environment.sends == 0, "passive copy delivers once without synthesizing another copy");
}

static void testActiveCopy() {
    Fixture f;
    f.begin(NO);
    [f.environment runUntil:0.1];
    require(f.quiet() && f.environment.sends == 0, "active copy waits for the gesture's release notification");
    // A change before release must not be mistaken for the synthesized copy.
    f.copy(@"unrelated earlier clipboard content");
    [f.reader readSelection];
    [f.reader readSelection];
    require(f.environment.sends == 0, "active copy is deferred beyond the release callback");
    [f.environment runUntil:0.1];
    require(f.environment.sends == 1, "one release schedules exactly one copy");
    [f.environment runUntil:0.161];
    require(f.quiet() && f.environment.reads == 0, "active copy snapshots the clipboard immediately before synthesis");
    f.copy(@"selected text");
    [f.environment runUntil:0.181];
    f.requireText(@"selected text", "active copy reads the synthesized copy's update on a later poll");
    [f.environment runUntil:1];
    require(f.texts.count == 1 && f.environment.sends == 1, "active read completes once");
}

static void testFailuresAndRecovery() {
    {
        Fixture f;
        f.begin();
        [f.reader readSelection];
        [f.environment runUntil:0.79];
        require(f.quiet(), "unchanged clipboard does not report an early timeout");
        [f.environment runUntil:0.81];
        f.requireProblem("unchanged clipboard reports one timeout");
        require(f.environment.reads == 0, "timeout never reads old clipboard text");
        [f.environment runUntil:1];
        require(f.problems.count == 1, "timeout does not repeat");
        f.begin();
        f.copy(@"recovered after timeout");
        [f.reader readSelection];
        [f.environment runUntil:1.061];
        require(f.texts.count == 1 && [f.texts[0] isEqualToString:@"recovered after timeout"],
                "a failed read does not prevent a later selection");
    }
    {
        Fixture f;
        f.begin();
        f.copy(@"inaccessible");
        f.environment.denied = YES;
        [f.reader readSelection];
        [f.environment runUntil:1];
        f.requireProblem("denied clipboard access reports one problem");
        require(f.environment.reads == 0, "denied clipboard text is never fetched");
    }
    for (NSString *text in @[@"", @" \n\t", NSNull.null]) {
        Fixture f;
        f.begin();
        f.copy(text == (id)NSNull.null ? nil : text);
        [f.reader readSelection];
        [f.environment runUntil:1];
        f.requireProblem("empty, whitespace-only and non-text copies each report one problem");
    }
    {
        Fixture f;
        f.environment.copySucceeds = NO;
        f.begin(NO);
        [f.reader readSelection];
        [f.environment runUntil:1];
        f.requireProblem("copy synthesis failure reports one problem");
        require(f.environment.sends == 1 && f.environment.reads == 0, "failed synthesis does not poll old text");
    }
}

static void testCancellationAndReplacement() {
    for (BOOL passive : {NO, YES}) {
        Fixture f;
        f.begin(passive);
        [f.reader readSelection];
        [f.reader cancel];
        f.copy(@"stale");
        [f.environment runUntil:1];
        require(f.quiet() && f.environment.sends == 0 && f.environment.reads == 0,
                "cancellation invalidates both deferred synthesis and deferred polling");
    }
    {
        Fixture f;
        f.begin(NO);
        [f.reader readSelection];
        f.begin();
        f.copy(@"new passive selection");
        [f.reader readSelection];
        [f.environment runUntil:1];
        f.requireText(@"new passive selection", "a new session invalidates an older queued copy");
        require(f.environment.sends == 0, "replaced active session never synthesizes copy");
    }
    {
        Fixture f;
        f.begin();
        [f.reader readSelection];
        [f.environment runUntil:0.03];
        f.copy(@"old selection");
        f.begin();
        [f.reader readSelection];
        [f.environment runUntil:0.061];
        require(f.quiet() && f.environment.reads == 0, "old poll cannot read using the new session's state");
        f.copy(@"new selection");
        [f.environment runUntil:0.091];
        f.requireText(@"new selection", "new polling session survives the stale poll");
    }
}

static void testApplicationChanges() {
    for (BOOL passive : {NO, YES}) {
        Fixture f;
        f.begin(passive);
        [f.reader readSelection];
        f.copy(@"from the previous application");
        ++f.environment.application;
        [f.environment runUntil:1];
        require(f.quiet() && f.environment.sends == 0 && f.environment.reads == 0,
                "application change invalidates queued synthesis and polling");
        --f.environment.application;
        [f.reader readSelection];
        [f.environment runUntil:2];
        require(f.quiet(), "returning to the source app cannot revive an invalidated read");
        f.begin();
        f.copy(@"fresh selection after returning");
        [f.reader readSelection];
        [f.environment runUntil:2.061];
        f.requireText(@"fresh selection after returning", "selection recovers after changing applications");
    }
    {
        Fixture f;
        FakeSelectionEnvironment *environment = f.environment;
        __weak FakeSelectionEnvironment *weakEnvironment = environment;
        f.begin();
        f.copy(@"stale promised data");
        environment.onRead = ^{ ++weakEnvironment.application; };
        [f.reader readSelection];
        [environment runUntil:1];
        require(f.quiet(), "source application is rechecked after a pasteboard read reenters the app");
    }
}

static void testReentrantReads() {
    {
        Fixture f;
        __weak SelectionReader *weakReader = f.reader;
        f.begin(NO);
        f.environment.onChangeCount = ^{ [weakReader cancel]; };
        [f.reader readSelection];
        [f.environment runUntil:1];
        require(f.quiet() && f.environment.sends == 0,
                "reentrant cancellation while taking the active baseline prevents synthesized copy");
    }
    for (BOOL replace : {NO, YES}) {
        Fixture f;
        SelectionReader *reader = f.reader;
        FakeSelectionEnvironment *environment = f.environment;
        __weak SelectionReader *weakReader = reader;
        __weak FakeSelectionEnvironment *weakEnvironment = environment;
        f.begin();
        f.copy(@"stale promised data");
        environment.onRead = ^{
            SelectionReader *reader = weakReader;
            FakeSelectionEnvironment *environment = weakEnvironment;
            [reader cancel];
            if (replace) {
                [reader beginCopyFromApplication:environment.application passive:YES];
                environment.text = @"replacement selection";
                ++environment.changeCount;
                [reader readSelection];
            }
        };
        [reader readSelection];
        [environment runUntil:0.061];
        require(f.quiet(), "reentrant cancel or replacement suppresses the old pasteboard result");
        if (replace) {
            [environment runUntil:0.121];
            f.requireText(@"replacement selection", "old completion does not invalidate a reentrant replacement");
        } else {
            f.begin();
            f.copy(@"fresh after reentrant cancellation");
            [reader readSelection];
            [environment runUntil:0.122];
            f.requireText(@"fresh after reentrant cancellation", "reader recovers after reentrant cancellation");
        }
    }
    {
        Fixture f;
        SelectionReader *reader = f.reader;
        FakeSelectionEnvironment *environment = f.environment;
        __weak SelectionReader *weakReader = reader;
        NSMutableArray<NSString *> *texts = f.texts;
        reader.onText = ^(NSString *text) {
            [texts addObject:text];
            if (texts.count == 1) {
                SelectionReader *reader = weakReader;
                [reader beginCopyFromApplication:environment.application passive:YES];
                environment.text = @"next selection";
                ++environment.changeCount;
                [reader readSelection];
            }
        };
        f.begin();
        f.copy(@"first selection");
        [reader readSelection];
        [environment runUntil:1];
        require(texts.count == 2 && [texts[0] isEqualToString:@"first selection"] &&
                [texts[1] isEqualToString:@"next selection"] && f.problems.count == 0,
                "completion clears its own session before the client starts another read");
        reader.onText = nil;
    }
}

int main() {
    @autoreleasepool {
        testPassiveCopy();
        testActiveCopy();
        testFailuresAndRecovery();
        testCancellationAndReplacement();
        testApplicationChanges();
        testReentrantReads();
        std::cout << "Selection reader tests passed without event taps or system clipboard access\n";
    }
}
