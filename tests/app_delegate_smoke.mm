#import "AppDelegate.h"
#import "TranslationPanel.h"
#import "ModelStore.h"

#include <cstdlib>
#include <iostream>
#include <stdexcept>

@interface AppDelegate (SmokeTest)
- (void)buildMenus;
- (void)updateStatus;
- (void)translateText:(NSString *)text direction:(bawan::Direction)direction;
- (void)warmUpEngine;
- (void)openTranslation:(id)sender;
- (void)cancelTranslation;
- (void)retryModel:(id)sender;
- (void)handleEngineEvent:(const bawan::EngineEvent &)event;
@end

@interface ModelStore (SmokeTest)
- (instancetype)initWithFileManager:(NSFileManager *)files expectedSize:(int64_t)expectedSize
    SHA256:(NSString *)expectedSHA256;
@end

@interface ModelFixtureFileManager : NSFileManager
@property(nonatomic, copy) NSURL *supportDirectory;
@end

@implementation ModelFixtureFileManager
- (NSURL *)URLForDirectory:(NSSearchPathDirectory)directory inDomain:(NSSearchPathDomainMask)domain
    appropriateForURL:(NSURL *)url create:(BOOL)create error:(NSError **)error {
    if (directory == NSApplicationSupportDirectory && domain == NSUserDomainMask) return _supportDirectory;
    return [super URLForDirectory:directory inDomain:domain appropriateForURL:url create:create error:error];
}
@end

static void Require(BOOL condition, NSString *message) {
    if (!condition) throw std::runtime_error(message.UTF8String);
}

static BOOL Flag(AppDelegate *delegate, NSString *key) {
    return [[delegate valueForKey:key] boolValue];
}

static NSView *FindView(NSView *root, NSString *identifier) {
    if ([root.identifier isEqualToString:identifier]) return root;
    for (NSView *child in root.subviews) {
        NSView *found = FindView(child, identifier);
        if (found) return found;
    }
    return nil;
}

template <typename Predicate>
static void WaitFor(Predicate predicate, NSString *message) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
    while (!predicate()) {
        Require(deadline.timeIntervalSinceNow > 0, message);
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

static void SetAvailableModel(AppDelegate *delegate) {
    [delegate setValue:[NSURL fileURLWithPath:@"/__bawan_tests__/missing-model.gguf"] forKey:@"modelURL"];
    [delegate setValue:@YES forKey:@"modelAvailable"];
    [delegate setValue:@NO forKey:@"modelFailed"];
    [delegate setValue:@"Ready to translate · On-device processing" forKey:@"modelStatus"];
    [delegate updateStatus];
}

static void RequireModelFailure(AppDelegate *delegate) {
    NSMenuItem *retry = [delegate valueForKey:@"retryItem"];
    NSMenuItem *model = [delegate valueForKey:@"modelItem"];
    NSString *status = [delegate valueForKey:@"modelStatus"];
    Require(Flag(delegate, @"modelFailed") && !Flag(delegate, @"busy") &&
        !retry.hidden && retry.enabled && status.length &&
        [model.title isEqualToString:status] && ![status isEqualToString:@"Loading the model…"],
        @"A model load failure must stop loading and expose Retry Model Setup");
    Require([[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue] == 0,
        @"A failed cold request must release the active request ID");
}

static void CheckPendingSelection(AppDelegate *delegate, TranslationPanel *panel) {
    [panel showForSelection:@"First selection"];
    [delegate translateText:@"First selection" direction:bawan::Direction::Automatic];
    [delegate translateText:@"Latest selection" direction:bawan::Direction::EnglishToJapanese];
    Require(Flag(delegate, @"busy") &&
        [[delegate valueForKey:@"pendingText"] isEqualToString:@"Latest selection"],
        @"Verification must retain only the latest requested selection");
    [delegate warmUpEngine];
    Require(Flag(delegate, @"warmUpWhenAvailable") &&
        [[delegate valueForKey:@"engineGeneration"] unsignedLongLongValue] == 0,
        @"Verification must defer inference engine creation");
    [panel close];
    Require(!Flag(delegate, @"busy") && !Flag(delegate, @"warmUpWhenAvailable") &&
        [delegate valueForKey:@"pendingText"] == nil &&
        [[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue] == 0,
        @"Closing during verification must clear queued translation and warmup work");
}

static void CheckEditedRequests(AppDelegate *delegate, TranslationPanel *panel) {
    [panel showForSelection:@"Original source"];
    [panel showForManualInput];
    NSWindow *window = [panel valueForKey:@"panel"];
    NSTextView *source = (NSTextView *)FindView(window.contentView, @"source");
    NSTextView *output = (NSTextView *)FindView(window.contentView, @"output");
    NSButton *translate = (NSButton *)FindView(window.contentView, @"translate");
    NSButton *copy = (NSButton *)FindView(window.contentView, @"copy");
    NSButton *swap = (NSButton *)FindView(window.contentView, @"swap");
    Require(source && output && translate && copy && swap, @"The edit fixture must find the real panel controls");

    [delegate translateText:source.string direction:bawan::Direction::Automatic];
    BOOL groupsByEvent = source.undoManager.groupsByEvent;
    source.undoManager.groupsByEvent = NO;
    [source.undoManager beginUndoGrouping];
    [source insertText:@"Revised queued source" replacementRange:NSMakeRange(0, source.string.length)];
    [source.undoManager endUndoGrouping];
    source.undoManager.groupsByEvent = groupsByEvent;
    Require(!Flag(delegate, @"busy") && [delegate valueForKey:@"pendingText"] == nil &&
        [[delegate valueForKey:@"engineGeneration"] unsignedLongLongValue] == 0 &&
        [source.string isEqualToString:@"Revised queued source"] && output.string.length == 0,
        @"Editing a queued source must discard the pending translation before model readiness");
    SetAvailableModel(delegate);
    Require([translate.title isEqualToString:@"Translate  ⌘↵"] && !copy.enabled && !swap.enabled,
        @"Model availability after an edit must leave the revised source ready for an explicit translation");

    [translate performClick:nil];
    uint64_t oldRequest = [[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue];
    Require(oldRequest != 0 && Flag(delegate, @"busy"), @"The edit fixture must start a real active request");
    bawan::EngineEvent partial{bawan::EngineEvent::Kind::Text, oldRequest, "Original partial output",
        false, bawan::Direction::EnglishToJapanese};
    [delegate handleEngineEvent:partial];
    Require([output.string isEqualToString:@"Original partial output"] && copy.enabled,
        @"The active request must display partial output before it is edited");
    [source breakUndoCoalescing];
    source.undoManager.groupsByEvent = NO;
    [source.undoManager beginUndoGrouping];
    [source insertText:@"Revised active source" replacementRange:NSMakeRange(0, source.string.length)];
    [source.undoManager endUndoGrouping];
    source.undoManager.groupsByEvent = groupsByEvent;
    Require(!Flag(delegate, @"busy") && [source.string isEqualToString:@"Revised active source"] &&
        output.string.length == 0 && !copy.enabled && !swap.enabled,
        @"Editing an active source must cancel translation and remove its partial output");
    for (auto kind : {bawan::EngineEvent::Kind::Text, bawan::EngineEvent::Kind::Complete}) {
        bawan::EngineEvent stale{kind, oldRequest, "Late original output", false, bawan::Direction::EnglishToJapanese};
        [delegate handleEngineEvent:stale];
    }
    Require(output.string.length == 0 && !copy.enabled && !swap.enabled && !Flag(delegate, @"busy"),
        @"Late text and completion must not restore output for an edited source");
    [source.undoManager undo];
    Require([source.string isEqualToString:@"Revised queued source"] && output.string.length == 0,
        [NSString stringWithFormat:@"Cancelling an active translation must preserve Undo without reviving its output; source=%@, output=%@",
            source.string, output.string]);
    [source.undoManager redo];
    Require([source.string isEqualToString:@"Revised active source"],
        [NSString stringWithFormat:@"Cancellation must preserve source Redo; source=%@", source.string]);

    [translate performClick:nil];
    uint64_t newRequest = [[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue];
    Require(newRequest != 0 && newRequest != oldRequest, @"The revised source must start a fresh request");
    bawan::EngineEvent staleComplete{bawan::EngineEvent::Kind::Complete, oldRequest, "Late original output",
        false, bawan::Direction::EnglishToJapanese};
    [delegate handleEngineEvent:staleComplete];
    Require(output.string.length == 0 && Flag(delegate, @"busy"),
        @"An old completion must not finish the revised source's request");
    bawan::EngineEvent revisedComplete{bawan::EngineEvent::Kind::Complete, newRequest, "Revised output",
        false, bawan::Direction::EnglishToJapanese};
    [delegate handleEngineEvent:revisedComplete];
    Require([output.string isEqualToString:@"Revised output"] && copy.enabled && swap.enabled && !Flag(delegate, @"busy"),
        @"The revised source's own completion must still enable Copy and Swap");
}

static void CheckRetainedResultStatus(AppDelegate *delegate, TranslationPanel *panel) {
    [panel showForSelection:@"A source sentence"];
    NSWindow *window = nil;
    for (NSWindow *candidate in NSApp.windows) {
        if ([candidate.contentView.identifier isEqualToString:@"bawan-panel"]) window = candidate;
    }
    NSTextView *output = (NSTextView *)FindView(window.contentView, @"output");
    NSTextField *status = (NSTextField *)FindView(window.contentView, @"status");
    NSButton *primary = (NSButton *)FindView(window.contentView, @"translate");
    Require(output && status && primary, @"Retained result checks require the real panel controls");

    auto beginRequest = [&](uint64_t requestId) {
        NSString *previousStatus = status.stringValue;
        [delegate setValue:@NO forKey:@"modelAvailable"];
        [delegate translateText:@"A source sentence" direction:bawan::Direction::EnglishToJapanese];
        Require(output.string.length == 0 &&
            (previousStatus.length == 0 || ![status.stringValue isEqualToString:previousStatus]),
            @"A new translation must clear the retained output and its previous result notice");
        [delegate setValue:nil forKey:@"pendingText"];
        [delegate setValue:@YES forKey:@"modelAvailable"];
        [delegate setValue:@(requestId) forKey:@"activeRequestId"];
        [delegate handleEngineEvent:bawan::EngineEvent{bawan::EngineEvent::Kind::Ready, 0}];
    };
    auto requireResult = [&](NSString *expectedOutput, NSString *expectedStatus) {
        Require([output.string isEqualToString:expectedOutput] && !status.hidden &&
            [status.stringValue isEqualToString:expectedStatus],
            @"Retained output must keep its cancellation, truncation or error notice");
    };
    auto reopenAndWarm = [&](NSString *expectedOutput, NSString *expectedStatus) {
        [panel close];
        [delegate openTranslation:nil];
        requireResult(expectedOutput, expectedStatus);
        [delegate handleEngineEvent:bawan::EngineEvent{bawan::EngineEvent::Kind::Loading, 0}];
        requireResult(expectedOutput, expectedStatus);
        [delegate handleEngineEvent:bawan::EngineEvent{bawan::EngineEvent::Kind::Ready, 0}];
        requireResult(expectedOutput, expectedStatus);
    };

    beginRequest(101);
    [delegate handleEngineEvent:bawan::EngineEvent{bawan::EngineEvent::Kind::Text, 101, "Partial translation"}];
    [primary performClick:nil];
    requireResult(@"Partial translation", @"Translation cancelled");
    reopenAndWarm(@"Partial translation", @"Translation cancelled");
    [delegate handleEngineEvent:bawan::EngineEvent{bawan::EngineEvent::Kind::Complete, 101, "Stale translation"}];
    requireResult(@"Partial translation", @"Translation cancelled");

    beginRequest(102);
    [delegate handleEngineEvent:bawan::EngineEvent{bawan::EngineEvent::Kind::Complete, 102, "Limited translation", true}];
    NSString *truncated = @"Output limit reached. The translation is incomplete. Select less text and try again.";
    requireResult(@"Limited translation", truncated);
    reopenAndWarm(@"Limited translation", truncated);

    beginRequest(103);
    [delegate handleEngineEvent:bawan::EngineEvent{bawan::EngineEvent::Kind::Text, 103, "Translation before error"}];
    [delegate handleEngineEvent:bawan::EngineEvent{bawan::EngineEvent::Kind::Error, 103, "Translation failed"}];
    reopenAndWarm(@"Translation before error", @"Translation failed");

    beginRequest(104);
    [delegate handleEngineEvent:bawan::EngineEvent{bawan::EngineEvent::Kind::Text, 104, "Translation before close"}];
    reopenAndWarm(@"Translation before close", @"Translation cancelled");

    beginRequest(105);
    [delegate handleEngineEvent:bawan::EngineEvent{bawan::EngineEvent::Kind::Complete, 105, "Complete translation"}];
    [panel close];
    [delegate openTranslation:nil];
    Require([output.string isEqualToString:@"Complete translation"] && status.hidden,
        @"A complete new translation must remain free of the previous result notice after reopening");
    beginRequest(106);
    [delegate handleEngineEvent:bawan::EngineEvent{bawan::EngineEvent::Kind::Complete, 106, "Limited translation", true}];
    [panel setOutput:@"" direction:bawan::Direction::Automatic];
    [delegate updateStatus];
    Require(output.string.length == 0 && status.hidden,
        @"Clearing output outside a translation request must discard its result notice");
    [panel setOutput:@"Complete translation" direction:bawan::Direction::EnglishToJapanese];
    [panel close];
    [delegate openTranslation:nil];
    Require([output.string isEqualToString:@"Complete translation"] && status.hidden,
        @"Restoring different output must not restore a notice from the discarded result");

    beginRequest(107);
    [delegate handleEngineEvent:bawan::EngineEvent{bawan::EngineEvent::Kind::Text, 107, "Partial translation"}];
    [primary performClick:nil];
    [panel setOutput:@"" direction:bawan::Direction::Automatic];
    [panel setOutput:@"Partial translation" direction:bawan::Direction::EnglishToJapanese];
    [panel close];
    [delegate openTranslation:nil];
    Require([output.string isEqualToString:@"Partial translation"] && status.hidden,
        @"Clearing then restoring the same output must not resurrect its old cancellation notice");
    [delegate setValue:@NO forKey:@"modelAvailable"];
}

static void CheckColdRequestAndRetry(AppDelegate *delegate) {
    SetAvailableModel(delegate);
    [delegate translateText:@"Hello" direction:bawan::Direction::EnglishToJapanese];
    Require(Flag(delegate, @"busy"), @"A cold translation must enter the cancellable busy state");
    WaitFor([&] { return Flag(delegate, @"modelFailed") && !Flag(delegate, @"busy"); },
        @"Cold model loading did not report its failure to the application");
    RequireModelFailure(delegate);

    [delegate translateText:@"Try again" direction:bawan::Direction::EnglishToJapanese];
    uint64_t oldGeneration = [[delegate valueForKey:@"engineGeneration"] unsignedLongLongValue];
    uint64_t oldRequest = [[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue];
    [delegate retryModel:nil];
    Require([[delegate valueForKey:@"engineGeneration"] unsignedLongLongValue] > oldGeneration,
        @"Retry must invalidate the previous engine's callback generation");
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    bawan::EngineEvent staleError{bawan::EngineEvent::Kind::Error, oldRequest, "Old request failed"};
    [delegate handleEngineEvent:staleError];
    NSMenuItem *retry = [delegate valueForKey:@"retryItem"];
    Require(!Flag(delegate, @"busy") && !Flag(delegate, @"modelFailed") &&
        !Flag(delegate, @"modelAvailable") && [delegate valueForKey:@"modelURL"] == nil &&
        [[delegate valueForKey:@"modelStatus"] isEqualToString:@"Checking the model…"] && retry.hidden,
        @"Old engine events must not overwrite model setup after Retry");
}

static void CheckWarmUpFailure(AppDelegate *delegate) {
    SetAvailableModel(delegate);
    [delegate warmUpEngine];
    Require(!Flag(delegate, @"busy"), @"Manual prewarming must not create a translation request");
    WaitFor([&] { return Flag(delegate, @"modelFailed"); },
        @"Model prewarming did not report its failure to the application");
    RequireModelFailure(delegate);
}

static void CheckModelRevalidationOnRetry(AppDelegate *delegate) {
    ModelFixtureFileManager *files = [[ModelFixtureFileManager alloc] init];
    files.supportDirectory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSURL *directory = [files.supportDirectory URLByAppendingPathComponent:@"local.bawan.Bawan" isDirectory:YES];
    NSURL *model = [directory URLByAppendingPathComponent:@"plamo-3-translate-0.8b-Q4_K_M.gguf"];
    NSData *valid = [@"valid model fixture" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *corrupt = [@"damaged model bytes" dataUsingEncoding:NSUTF8StringEncoding];
    ModelStore *store = [[ModelStore alloc] initWithFileManager:files expectedSize:valid.length
        SHA256:@"32e5e24230b47f8db398a288c8a7ca84723ba83d0099fceeaecdec1976d25c30"];
    ModelStore *previousStore = [delegate valueForKey:@"modelStore"];
    __block NSUInteger ready = 0;
    __block NSUInteger errors = 0;
    __block NSURL *lastReadyURL = nil;
    __block NSString *lastError = nil;
    store.onReady = ^(NSURL *url) { ++ready; lastReadyURL = url; };
    store.onError = ^(NSString *message) { ++errors; lastError = message; };
    @try {
        Require([files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil],
            @"The model retry fixture directory must be created");
        Require([valid writeToURL:model atomically:YES], @"The valid model fixture must be written");
        [delegate setValue:store forKey:@"modelStore"];
        [store prepare];
        WaitFor(^BOOL { return ready || errors; }, @"Initial fixture verification did not complete");
        Require(ready == 1 && errors == 0 && [lastReadyURL isEqual:model],
            @"The original model fixture must pass real SHA256 verification at its fixture path");

        Require(valid.length == corrupt.length, @"The corruption fixture must preserve model size");
        Require([corrupt writeToURL:model atomically:YES], @"The same-path model must be corrupted");
        [delegate retryModel:nil];
        WaitFor(^BOOL { return ready > 1 || errors; }, @"Retry did not revalidate the changed model");
        Require(ready == 1 && errors == 1 && [lastError containsString:@"SHA256"],
            @"Retry must reject changed model bytes with a SHA256 error instead of reporting Ready");
        Require(![files fileExistsAtPath:model.path], @"Retry must remove the model proven corrupt");

        Require([valid writeToURL:model atomically:YES], @"The valid model fixture must be restored");
        [delegate retryModel:nil];
        WaitFor(^BOOL { return ready > 1 || errors > 1; }, @"Retry did not verify the restored model");
        Require(ready == 2 && errors == 1, @"Retry must accept the restored valid model");
    } @finally {
        [store cancel];
        [delegate setValue:previousStore forKey:@"modelStore"];
        [files removeItemAtURL:files.supportDirectory error:nil];
    }
}

int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        TranslationPanel *panel = [[TranslationPanel alloc] init];
        [delegate setValue:panel forKey:@"translationPanel"];
        [delegate setValue:@"Checking the model…" forKey:@"modelStatus"];
        __weak AppDelegate *weakDelegate = delegate;
        panel.onTranslate = ^(NSString *text, bawan::Direction direction) {
            [weakDelegate translateText:text direction:direction];
        };
        panel.onCancel = ^{ [weakDelegate cancelTranslation]; };
        panel.onClose = ^{ [weakDelegate cancelTranslation]; };
        [delegate buildMenus];
        [delegate updateStatus];
        int result = EXIT_SUCCESS;
        @try {
            try {
                CheckPendingSelection(delegate, panel);
                CheckEditedRequests(delegate, panel);
                CheckRetainedResultStatus(delegate, panel);
                CheckColdRequestAndRetry(delegate);
                CheckWarmUpFailure(delegate);
                CheckModelRevalidationOnRetry(delegate);
                std::cout << "PASS: pending selection cancellation, source edits, stale output isolation, retained result notices, cold load errors, warmup errors, retry isolation and model revalidation\n";
            } catch (const std::exception &error) {
                std::cerr << "FAIL: " << error.what() << '\n';
                result = EXIT_FAILURE;
            }
        } @finally {
            [panel close];
            [delegate applicationWillTerminate:nil];
        }
        return result;
    }
}
