#import "AppDelegate.h"
#import "TranslationPanel.h"
#import "ModelStore.h"
#import "OnboardingViewController.h"
#import "BawanAppearance.h"

#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <iostream>
#include <stdexcept>

@interface AppDelegate (SmokeTest)
- (void)buildMenus;
- (void)updateStatus;
- (void)translateText:(NSString *)text direction:(bawan::Direction)direction;
- (void)warmUpEngine;
- (void)cancelTranslation;
- (void)retryModel:(id)sender;
- (void)handleEngineEvent:(const bawan::EngineEvent &)event;
- (void)handleSelectionText:(NSString *)text;
- (void)handleShortcutProblem:(NSString *)message;
- (void)modelFileDidProgress:(double)progress message:(NSString *)message;
- (void)modelFileDidBecomeReady:(NSURL *)fileURL;
- (void)modelFileDidFail:(NSString *)message;
- (void)startInitialSetup;
- (void)showOnboarding;
- (void)beginModelSetup;
- (void)finishOnboarding;
- (void)openTranslation:(id)sender;
- (void)openSettings:(id)sender;
- (void)requestModelLicenseAcceptance:(void (^)(BOOL accepted))completion;
@end

@interface EngineSmokeDelegate : AppDelegate
@property(nonatomic) BOOL holdEngineCallbacks;
@property(nonatomic) uint64_t observedRequestId;
@property(nonatomic, copy) void (^onTranslation)(NSString *text, bawan::Direction direction);
@property(nonatomic, copy) void (^onWarmUp)(void);
- (void)injectEngineEvent:(const bawan::EngineEvent &)event;
@end

@implementation EngineSmokeDelegate
- (void)handleEngineEvent:(const bawan::EngineEvent &)event {
    if (event.requestId) _observedRequestId = event.requestId;
    if (!_holdEngineCallbacks) [super handleEngineEvent:event];
}
- (void)injectEngineEvent:(const bawan::EngineEvent &)event { [super handleEngineEvent:event]; }
- (void)translateText:(NSString *)text direction:(bawan::Direction)direction {
    if (_onTranslation) _onTranslation(text, direction);
    [super translateText:text direction:direction];
}
- (void)warmUpEngine {
    if (_onWarmUp) _onWarmUp();
    [super warmUpEngine];
}
@end

@interface SetupSmokeDelegate : EngineSmokeDelegate
@property(nonatomic) BOOL allowLicense;
@property(nonatomic) NSUInteger licenseViews;
@property(nonatomic) NSUInteger warmUps;
@end

@implementation SetupSmokeDelegate
- (void)requestModelLicenseAcceptance:(void (^)(BOOL accepted))completion {
    ++_licenseViews;
    completion(_allowLicense);
}
- (void)warmUpEngine { ++_warmUps; }
@end

@interface SetupSmokeStore : ModelStore
@property(nonatomic) NSUInteger preparations;
@property(nonatomic) NSUInteger revalidations;
@end

@implementation SetupSmokeStore
- (void)prepare { ++_preparations; }
- (void)revalidate { ++_revalidations; ++_preparations; }
- (void)cancel {}
@end

@interface SetupSmokeMonitor : ShortcutMonitor
@property(nonatomic) NSUInteger permissionRequests;
@end

@implementation SetupSmokeMonitor
- (void)start {}
- (void)stop {}
- (void)refresh {}
- (ShortcutAvailability)availabilityForAction:(bawan::ShortcutAction)action {
    return action == bawan::ShortcutAction::TranslateSelection ?
        ShortcutAvailabilityNeedsInputMonitoring : ShortcutAvailabilityNeedsAccessibility;
}
- (void)requestPermissionForAction:(bawan::ShortcutAction)action { ++_permissionRequests; }
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

class ScopedEngineCallbackSuppression final {
public:
    explicit ScopedEngineCallbackSuppression(EngineSmokeDelegate *delegate) : delegate_(delegate),
        previous_(delegate.holdEngineCallbacks) {
        delegate_.holdEngineCallbacks = YES;
    }

    ~ScopedEngineCallbackSuppression() { delegate_.holdEngineCallbacks = previous_; }

    ScopedEngineCallbackSuppression(const ScopedEngineCallbackSuppression &) = delete;
    ScopedEngineCallbackSuppression &operator=(const ScopedEngineCallbackSuppression &) = delete;

private:
    EngineSmokeDelegate *__strong delegate_;
    BOOL previous_;
};

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

static uint64_t ObserveRequest(EngineSmokeDelegate *delegate, void (^start)(void)) {
    Require(delegate.holdEngineCallbacks, @"Synthetic outcomes must hold the real engine callbacks");
    delegate.observedRequestId = 0;
    start();
    WaitFor([&] { return delegate.observedRequestId != 0; },
        @"The real engine did not deliver a request-scoped callback");
    return delegate.observedRequestId;
}

static NSButton *TranslateButton(TranslationPanel *panel) {
    NSButton *button = (NSButton *)FindView(panel.window.contentView, @"translate");
    Require(button != nil, @"The delegate fixture must use the real Translate/Cancel button");
    return button;
}

static BOOL IsCancellable(TranslationPanel *panel) {
    NSButton *button = TranslateButton(panel);
    BOOL showsCancel = [button.title isEqualToString:@"Cancel  ⌘↵"];
    Require(!showsCancel || button.enabled, @"The Cancel action must remain enabled");
    return showsCancel;
}

static NSMenuItem *RetryItem(AppDelegate *delegate) {
    NSStatusItem *statusItem = [delegate valueForKey:@"statusItem"];
    for (NSMenuItem *item in statusItem.menu.itemArray) {
        if (item.action == @selector(retryModel:)) return item;
    }
    Require(NO, @"The status menu must contain Retry Model Setup");
    return nil;
}

static NSMenuItem *ModelItem(AppDelegate *delegate) {
    for (NSMenuItem *item in RetryItem(delegate).menu.itemArray) {
        if (!item.action && !item.separatorItem && !item.enabled) return item;
    }
    Require(NO, @"The status menu must contain a model status label");
    return nil;
}

static void SetAvailableModel(AppDelegate *delegate) {
    [delegate modelFileDidBecomeReady:[NSURL fileURLWithPath:@"/__bawan_tests__/missing-model.gguf"]];
}

static void RequireModelFailure(AppDelegate *delegate, TranslationPanel *panel) {
    NSMenuItem *retry = RetryItem(delegate);
    NSString *message = ModelItem(delegate).title;
    NSTextField *status = (NSTextField *)FindView(panel.window.contentView, @"status");
    Require(!IsCancellable(panel) && !retry.hidden && retry.enabled &&
        [retry.title isEqualToString:@"Retry Model Setup"] && message.length &&
        ![message isEqualToString:@"Loading the model…"] &&
        !status.hidden && [status.stringValue isEqualToString:message] &&
        [status.textColor isEqual:BawanColor(BawanError)],
        @"A model load failure must stop loading and expose the same error in the translator and status menu");
}

static void CheckPendingSelection(EngineSmokeDelegate *delegate, TranslationPanel *panel) {
    ScopedEngineCallbackSuppression callbacks(delegate);
    [panel showForSelection:@"First selection"];
    [delegate translateText:@"First selection" direction:bawan::Direction::Automatic];
    [panel showForSelection:@"Latest selection"];
    [delegate translateText:@"Latest selection" direction:bawan::Direction::EnglishToJapanese];
    [delegate warmUpEngine];
    Require(IsCancellable(panel), @"A selection waiting for verification must remain cancellable");
    __block NSString *resumedText = nil;
    __block bawan::Direction resumedDirection = bawan::Direction::Automatic;
    delegate.onTranslation = ^(NSString *text, bawan::Direction direction) {
        resumedText = text;
        resumedDirection = direction;
    };
    uint64_t request = ObserveRequest(delegate, ^{ SetAvailableModel(delegate); });
    delegate.onTranslation = nil;
    Require([resumedText isEqualToString:@"Latest selection"] &&
        resumedDirection == bawan::Direction::EnglishToJapanese && IsCancellable(panel),
        @"Verification must resume the latest selection and direction, ahead of deferred warmup");
    [panel close];
    Require(!panel.window.visible && !IsCancellable(panel),
        @"Closing an active request must hide the translator and end its Cancel action");
    bawan::EngineEvent late{bawan::EngineEvent::Kind::Complete, request, "Closed request output"};
    [delegate injectEngineEvent:late];
    NSTextView *output = (NSTextView *)FindView(panel.window.contentView, @"output");
    Require(output.string.length == 0, @"A closed request must ignore late output");

    [delegate retryModel:nil];
    [panel showForSelection:@"Close before verification"];
    [delegate translateText:@"Close before verification" direction:bawan::Direction::Automatic];
    [delegate warmUpEngine];
    [panel close];
    __block BOOL resumed = NO;
    __block BOOL warmed = NO;
    delegate.onTranslation = ^(NSString *, bawan::Direction) { resumed = YES; };
    delegate.onWarmUp = ^{ warmed = YES; };
    SetAvailableModel(delegate);
    delegate.onTranslation = nil;
    delegate.onWarmUp = nil;
    Require(!resumed && !warmed && !IsCancellable(panel) && !panel.window.visible && RetryItem(delegate).hidden,
        @"Closing during verification must discard queued translation and warmup before the model becomes available");
    [delegate retryModel:nil];
}

static void CheckEditedRequests(EngineSmokeDelegate *delegate, TranslationPanel *panel) {
    [panel showForSelection:@"Original source"];
    [panel showForManualInput];
    NSWindow *window = panel.window;
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
    Require(!IsCancellable(panel) &&
        [source.string isEqualToString:@"Revised queued source"] && output.string.length == 0,
        @"Editing a queued source must discard the pending translation before model readiness");
    SetAvailableModel(delegate);
    Require([translate.title isEqualToString:@"Translate  ⌘↵"] && !copy.enabled && !swap.enabled,
        @"Model availability after an edit must leave the revised source ready for an explicit translation");

    ScopedEngineCallbackSuppression callbacks(delegate);
    uint64_t oldRequest = ObserveRequest(delegate, ^{ [translate performClick:nil]; });
    Require(IsCancellable(panel), @"The edit fixture must start a cancellable request");
    bawan::EngineEvent partial{bawan::EngineEvent::Kind::Text, oldRequest, "Original partial output",
        false, bawan::Direction::EnglishToJapanese};
    [delegate injectEngineEvent:partial];
    Require([output.string isEqualToString:@"Original partial output"] && copy.enabled,
        @"The active request must display partial output before it is edited");
    [source breakUndoCoalescing];
    source.undoManager.groupsByEvent = NO;
    [source.undoManager beginUndoGrouping];
    [source insertText:@"Revised active source" replacementRange:NSMakeRange(0, source.string.length)];
    [source.undoManager endUndoGrouping];
    source.undoManager.groupsByEvent = groupsByEvent;
    Require(!IsCancellable(panel) && [source.string isEqualToString:@"Revised active source"] &&
        output.string.length == 0 && !copy.enabled && !swap.enabled,
        @"Editing an active source must cancel translation and remove its partial output");
    for (auto kind : {bawan::EngineEvent::Kind::Text, bawan::EngineEvent::Kind::Complete}) {
        bawan::EngineEvent stale{kind, oldRequest, "Late original output", false, bawan::Direction::EnglishToJapanese};
        [delegate injectEngineEvent:stale];
    }
    Require(output.string.length == 0 && !copy.enabled && !swap.enabled && !IsCancellable(panel),
        @"Late text and completion must not restore output for an edited source");
    [source.undoManager undo];
    Require([source.string isEqualToString:@"Revised queued source"] && output.string.length == 0,
        [NSString stringWithFormat:@"Cancelling an active translation must preserve Undo without reviving its output; source=%@, output=%@",
            source.string, output.string]);
    [source.undoManager redo];
    Require([source.string isEqualToString:@"Revised active source"],
        [NSString stringWithFormat:@"Cancellation must preserve source Redo; source=%@", source.string]);

    uint64_t newRequest = ObserveRequest(delegate, ^{
        [NSApp sendAction:translate.action to:translate.target from:translate];
    });
    Require(newRequest != oldRequest && IsCancellable(panel), @"The revised source must start a fresh cancellable request");
    bawan::EngineEvent staleComplete{bawan::EngineEvent::Kind::Complete, oldRequest, "Late original output",
        false, bawan::Direction::EnglishToJapanese};
    [delegate injectEngineEvent:staleComplete];
    Require(output.string.length == 0 && IsCancellable(panel),
        @"An old completion must not finish the revised source's request");
    bawan::EngineEvent revisedComplete{bawan::EngineEvent::Kind::Complete, newRequest, "Revised output",
        false, bawan::Direction::EnglishToJapanese};
    [delegate injectEngineEvent:revisedComplete];
    Require([output.string isEqualToString:@"Revised output"] && copy.enabled && swap.enabled && !IsCancellable(panel),
        @"The revised source's own completion must still enable Copy and Swap");
}

static void CheckColdRequestAndRetry(EngineSmokeDelegate *delegate, TranslationPanel *panel) {
    SetAvailableModel(delegate);
    [delegate translateText:@"Hello" direction:bawan::Direction::EnglishToJapanese];
    Require(IsCancellable(panel), @"A cold translation must offer Cancel");
    WaitFor([&] { return !RetryItem(delegate).hidden && !IsCancellable(panel); },
        @"Cold model loading did not report its failure to the application");
    RequireModelFailure(delegate, panel);
    for (auto kind : {bawan::EngineEvent::Kind::Text, bawan::EngineEvent::Kind::Complete}) {
        bawan::EngineEvent late{kind, delegate.observedRequestId, "Failed request output"};
        [delegate injectEngineEvent:late];
    }
    NSTextView *output = (NSTextView *)FindView(panel.window.contentView, @"output");
    Require(output.string.length == 0 && !IsCancellable(panel) && !RetryItem(delegate).hidden,
        @"A failed request must not accept late text or completion");

    [delegate translateText:@"Try again" direction:bawan::Direction::EnglishToJapanese];
    [delegate retryModel:nil];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    bawan::EngineEvent staleError{bawan::EngineEvent::Kind::Error, delegate.observedRequestId, "Old request failed"};
    Require(staleError.requestId != 0, @"The cold request must have delivered a request-scoped error");
    [delegate injectEngineEvent:staleError];
    NSTextField *status = (NSTextField *)FindView(panel.window.contentView, @"status");
    NSMenuItem *retry = RetryItem(delegate);
    Require(!IsCancellable(panel) && !TranslateButton(panel).enabled &&
        [ModelItem(delegate).title isEqualToString:@"Checking the model…"] &&
        !status.hidden && [status.stringValue isEqualToString:@"Checking the model…"] &&
        retry.hidden && !retry.enabled,
        @"Old engine events must not overwrite model setup or enable translation after Retry");
}

static void CheckWarmUpFailure(AppDelegate *delegate, TranslationPanel *panel) {
    SetAvailableModel(delegate);
    [delegate warmUpEngine];
    Require(!IsCancellable(panel) && TranslateButton(panel).enabled,
        @"Manual prewarming must leave the Translate action available");
    WaitFor([&] { return !RetryItem(delegate).hidden; },
        @"Model prewarming did not report its failure to the application");
    RequireModelFailure(delegate, panel);
}

static void CheckModelStatusPresentation(EngineSmokeDelegate *delegate, TranslationPanel *panel) {
    using Kind = bawan::EngineEvent::Kind;
    [delegate retryModel:nil];
    [panel showForSelection:@"Keep this input after cancellation"];
    NSTextField *status = (NSTextField *)FindView(panel.window.contentView, @"status");
    NSButton *translate = (NSButton *)FindView(panel.window.contentView, @"translate");
    Require(status && translate, @"The status fixture must use the real translator controls");
    auto requireStatus = [&](NSString *message, BawanColorRole role) {
        Require([status.stringValue isEqualToString:message] && !status.hidden &&
            [status.textColor isEqual:BawanColor(role)],
            [NSString stringWithFormat:@"The translator must preserve its status %@; actual=%@", message, status.stringValue]);
    };

    [delegate translateText:@"Keep this input after cancellation" direction:bawan::Direction::Automatic];
    [delegate cancelTranslation];
    requireStatus(@"Translation cancelled", BawanSecondaryText);
    Require(!translate.enabled, @"Cancelling a queued request must still wait for the model file");
    SetAvailableModel(delegate);
    requireStatus(@"Translation cancelled", BawanSecondaryText);
    Require(translate.enabled && !IsCancellable(panel),
        @"A verified file must enable translation even while preserving the cancellation message");

    ScopedEngineCallbackSuppression callbacks(delegate);
    bawan::EngineEvent loading{Kind::Loading, 0, {}};
    bawan::EngineEvent ready{Kind::Ready, 0, {}};
    bawan::EngineEvent loadError{Kind::Error, 0, "Could not load the verified model"};
    [delegate injectEngineEvent:loading];
    [delegate updateStatus];
    requireStatus(@"Loading the model…", BawanSecondaryText);
    [delegate injectEngineEvent:loadError];
    [delegate updateStatus];
    requireStatus(@"Could not load the verified model", BawanError);
    [delegate injectEngineEvent:ready];
    Require(status.hidden, @"Model readiness must clear the preceding model error");

    struct Outcome {
        Kind kind;
        bool truncated;
        const char *text;
        NSString *message;
        BawanColorRole color;
    };
    const Outcome outcomes[] = {
        {Kind::Complete, true, "Partial translation",
            @"Output limit reached. The translation is incomplete. Select less text and try again.", BawanWarning},
        {Kind::Error, false, "Inference failed", @"Inference failed", BawanError},
        {Kind::Cancelled, false, "", @"Translation cancelled", BawanSecondaryText}
    };
    for (const Outcome &outcome : outcomes) {
        uint64_t request = ObserveRequest(delegate, ^{
            [delegate translateText:@"Try translating" direction:bawan::Direction::Automatic];
        });
        Require(IsCancellable(panel) && status.hidden, @"A new request must clear the previous translation outcome");
        [delegate injectEngineEvent:loading];
        [delegate updateStatus];
        requireStatus(@"Loading the model…", BawanSecondaryText);
        [delegate injectEngineEvent:ready];
        Require(status.hidden && IsCancellable(panel),
            @"Model readiness must clear Loading without completing the active translation");
        bawan::EngineEvent terminal{outcome.kind, request, outcome.text, outcome.truncated};
        [delegate injectEngineEvent:terminal];
        [delegate updateStatus];
        requireStatus(outcome.message, outcome.color);
        Require(!IsCancellable(panel), @"A translation outcome must release the busy state");
        [delegate injectEngineEvent:ready];
        bawan::EngineEvent idleCancellation{Kind::Cancelled, 0, {}};
        [delegate injectEngineEvent:idleCancellation];
        requireStatus(outcome.message, outcome.color);
        [delegate injectEngineEvent:loading];
        requireStatus(@"Loading the model…", BawanSecondaryText);
        [delegate injectEngineEvent:ready];
        Require(status.hidden, @"Ready must clear a model message that took ownership after a translation outcome");
    }

    ObserveRequest(delegate, ^{
        [delegate translateText:@"Cancel loading" direction:bawan::Direction::Automatic];
    });
    [delegate injectEngineEvent:loading];
    [delegate cancelTranslation];
    bawan::EngineEvent cancelled{Kind::Cancelled, 0, {}};
    [delegate injectEngineEvent:cancelled];
    [delegate updateStatus];
    requireStatus(@"Translation cancelled", BawanSecondaryText);
}

static void CheckShortcutStatusPresentation(EngineSmokeDelegate *delegate, TranslationPanel *panel) {
    using Kind = bawan::EngineEvent::Kind;
    SetAvailableModel(delegate);
    NSString *warning = @"The selected text could not be copied. Check shortcut permissions.";
    [delegate handleShortcutProblem:warning];
    NSTextField *status = (NSTextField *)FindView(panel.window.contentView, @"status");
    Require(status != nil, @"A shortcut problem must reveal the translator's status");
    auto requireWarning = [&] {
        Require(!status.hidden && [status.stringValue isEqualToString:warning] &&
            [status.textColor isEqual:BawanColor(BawanWarning)],
            @"Ready model updates must preserve the shortcut warning and its severity");
    };
    requireWarning();
    for (auto kind : {Kind::Ready, Kind::Cancelled}) {
        bawan::EngineEvent event{kind, 0, {}};
        [delegate injectEngineEvent:event];
        [delegate updateStatus];
        requireWarning();
    }
    bawan::EngineEvent loading{Kind::Loading, 0, {}};
    bawan::EngineEvent ready{Kind::Ready, 0, {}};
    [delegate injectEngineEvent:loading];
    Require(!status.hidden && [status.stringValue isEqualToString:@"Loading the model…"],
        @"A model load must take ownership from an earlier shortcut warning");
    [delegate injectEngineEvent:ready];
    Require(status.hidden, @"Ready must clear Loading without restoring the superseded shortcut warning");
    [delegate injectEngineEvent:loading];
    [delegate handleShortcutProblem:warning];
    [delegate injectEngineEvent:ready];
    requireWarning();

    ScopedEngineCallbackSuppression callbacks(delegate);
    uint64_t request = ObserveRequest(delegate, ^{
        [delegate translateText:@"Try translating after a shortcut warning" direction:bawan::Direction::Automatic];
    });
    Require(IsCancellable(panel) && status.hidden, @"A new translation must clear the shortcut warning");
    bawan::EngineEvent complete{Kind::Complete, request, "Successful translation"};
    [delegate injectEngineEvent:complete];
    [delegate injectEngineEvent:ready];
    Require(status.hidden && !IsCancellable(panel),
        @"A successful translation must leave no status for a later Ready update to restore");
}

static void CheckModelRevalidationOnRetry(AppDelegate *delegate, ModelStore *previousStore) {
    ModelFixtureFileManager *files = [[ModelFixtureFileManager alloc] init];
    files.supportDirectory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSURL *directory = [files.supportDirectory URLByAppendingPathComponent:@"local.bawan.Bawan" isDirectory:YES];
    NSURL *model = [directory URLByAppendingPathComponent:@"plamo-3-translate-0.8b-Q4_K_M.gguf"];
    NSData *valid = [@"valid model fixture" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *corrupt = [@"damaged model bytes" dataUsingEncoding:NSUTF8StringEncoding];
    ModelStore *store = [[ModelStore alloc] initWithFileManager:files expectedSize:valid.length
        SHA256:@"32e5e24230b47f8db398a288c8a7ca84723ba83d0099fceeaecdec1976d25c30"];
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

        Require(getxattr(model.fileSystemRepresentation, "local.bawan.verified-sha256", nullptr, 0, 0, 0) > 0,
            @"A verified model must carry its verification stamp");

        Require(valid.length == corrupt.length, @"The corruption fixture must preserve model size");
        struct stat original {};
        Require(stat(model.fileSystemRepresentation, &original) == 0, @"The model fixture must be readable");
        FILE *inPlace = std::fopen(model.fileSystemRepresentation, "r+b");
        Require(inPlace && std::fwrite(corrupt.bytes, 1, corrupt.length, inPlace) == corrupt.length &&
            std::fclose(inPlace) == 0, @"The model must be corrupted in place");
        const struct timespec times[2] = {original.st_atimespec, original.st_mtimespec};
        Require(utimensat(AT_FDCWD, model.fileSystemRepresentation, times, 0) == 0,
            @"The in-place corruption must keep the verified modification time");
        [store prepare];
        WaitFor(^BOOL { return ready > 1 || errors; }, @"Stamped model check did not complete");
        Require(ready == 2 && errors == 0, @"Launch must trust an unchanged verification stamp without rehashing");

        [delegate retryModel:nil];
        WaitFor(^BOOL { return ready > 2 || errors; }, @"Retry did not revalidate the changed model");
        Require(ready == 2 && errors == 1 && [lastError containsString:@"SHA256"],
            @"Retry must reject changed model bytes with a SHA256 error instead of reporting Ready");
        Require(![files fileExistsAtPath:model.path], @"Retry must remove the model proven corrupt");

        Require([corrupt writeToURL:model atomically:YES], @"An unstamped model must be written");
        [store prepare];
        WaitFor(^BOOL { return ready > 2 || errors > 1; }, @"Unstamped model check did not complete");
        Require(ready == 2 && errors == 2 && [lastError containsString:@"SHA256"],
            @"Launch must hash a model without a matching verification stamp");

        Require([valid writeToURL:model atomically:YES], @"The valid model fixture must be restored");
        [delegate retryModel:nil];
        WaitFor(^BOOL { return ready > 2 || errors > 2; }, @"Retry did not verify the restored model");
        Require(ready == 3 && errors == 2, @"Retry must accept the restored valid model");
    } @finally {
        [store cancel];
        [delegate setValue:previousStore forKey:@"modelStore"];
        [files removeItemAtURL:files.supportDirectory error:nil];
    }
}

static NSEvent *SetupKey(NSWindow *window, NSString *characters, NSEventModifierFlags modifiers, CGKeyCode keyCode) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:modifiers
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
        characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:keyCode];
}

static void CheckFirstRunIntegration(void) {
    NSString *suite = [@"local.bawan.FirstRunSmoke." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removePersistentDomainForName:suite];
    ShortcutPreferences *preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
    SetupSmokeMonitor *monitor = [[SetupSmokeMonitor alloc] initWithPreferences:preferences];
    SetupSmokeStore *store = [[SetupSmokeStore alloc] init];
    SetupSmokeDelegate *delegate = [[SetupSmokeDelegate alloc] init];
    TranslationPanel *panel = [[TranslationPanel alloc] init];
    [delegate setValue:defaults forKey:@"defaults"];
    [delegate setValue:preferences forKey:@"shortcutPreferences"];
    [delegate setValue:monitor forKey:@"shortcut"];
    [delegate setValue:store forKey:@"modelStore"];
    [delegate setValue:panel forKey:@"translationPanel"];
    [delegate buildMenus];
    __weak SetupSmokeDelegate *weakDelegate = delegate;
    panel.onClose = ^{ [weakDelegate cancelTranslation]; };
    __block NSUInteger translations = 0;
    panel.onTranslate = ^(NSString *, bawan::Direction) { ++translations; };
    SetupSmokeDelegate *existingUser = nil;
    TranslationPanel *existingPanel = nil;
    @try {
        Require(panel.currentPage == BawanPanelPageTranslation && !panel.window.visible,
            @"A new hidden panel must select the translator");
        [panel showForManualInput];
        NSWindow *window = panel.window;
        NSTextView *source = (NSTextView *)FindView(window.contentView, @"source");
        NSTextView *output = (NSTextView *)FindView(window.contentView, @"output");
        Require(source && output, @"The first-run integration must use the real translator controls");
        [delegate handleSelectionText:@"A selection waiting for setup"];
        Require(panel.currentPage == BawanPanelPageOnboarding &&
            [window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
            store.preparations == 0 && delegate.licenseViews == 0,
            @"A selection before model consent must show setup without entering an unstarted busy queue");
        [panel showForManualInput];
        Require(panel.currentPage == BawanPanelPageTranslation &&
            [source.string isEqualToString:@"A selection waiting for setup"],
            @"Returning from unfinished setup must preserve the selected text for later translation");
        Require(!IsCancellable(panel), @"An unprepared selection must leave the translator out of Cancel mode");
        source.string = @"Original source";
        NSMutableString *edited = [NSMutableString string];
        for (NSUInteger line = 0; line < 40; ++line) {
            [edited appendFormat:@"Line %lu remains editable after setup.\n", (unsigned long)line];
        }
        BOOL groupsByEvent = source.undoManager.groupsByEvent;
        source.undoManager.groupsByEvent = NO;
        [source.undoManager beginUndoGrouping];
        [source insertText:edited replacementRange:NSMakeRange(0, source.string.length)];
        [source.undoManager endUndoGrouping];
        source.undoManager.groupsByEvent = groupsByEvent;
        [source.layoutManager ensureLayoutForTextContainer:source.textContainer];
        [source sizeToFit];
        [source scrollRangeToVisible:NSMakeRange(500, 0)];
        source.selectedRange = NSMakeRange(25, 8);
        const NSPoint readingOrigin = source.enclosingScrollView.contentView.bounds.origin;
        [panel setOutput:@"A saved translation" direction:bawan::Direction::EnglishToJapanese];

        [delegate startInitialSetup];
        Require(panel.currentPage == BawanPanelPageOnboarding &&
            [window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
            store.preparations == 0 && delegate.licenseViews == 0 &&
            ![defaults boolForKey:@"firstLaunchShown"],
            @"First launch must show guidance without downloading, showing a modal license, or marking it complete");
        NSView *onboardingContent = window.contentView;
        [window orderOut:nil];
        Require(!window.visible && panel.currentPage == BawanPanelPageOnboarding,
            @"Hiding the window must retain the selected onboarding page");
        [delegate showOnboarding];
        Require(window.visible && panel.currentPage == BawanPanelPageOnboarding &&
            window.contentView == onboardingContent,
            @"Reopening onboarding must retain its selected page and content");
        Require(window.undoManager == nil, @"The onboarding page must isolate the translator's undo history");
        NSInteger pasteboardCount = NSPasteboard.generalPasteboard.changeCount;
        [window performKeyEquivalent:SetupKey(window, @"\r", NSEventModifierFlagCommand, 36)];
        [window performKeyEquivalent:SetupKey(window, @"c", NSEventModifierFlagCommand | NSEventModifierFlagShift, 8)];
        Require(translations == 0 && NSPasteboard.generalPasteboard.changeCount == pasteboardCount &&
            delegate.licenseViews == 1 && store.preparations == 0,
            @"While onboarding is visible, ⌘Return must mean Download (asking for the license) and never Translate or Copy");
        delegate.licenseViews = 0;
        [window cancelOperation:nil];
        Require(!window.visible && panel.currentPage == BawanPanelPageTranslation &&
            ![defaults boolForKey:@"firstLaunchShown"],
            @"Escape before model readiness must close guidance without recording completion");

        [delegate startInitialSetup];
        NSButton *primary = (NSButton *)FindView(window.contentView, @"onboarding-primary");
        Require(primary && !primary.hiddenOrHasHiddenAncestor && [primary.title hasPrefix:@"Download Model"],
            @"The model step's footer action must offer Download");
        delegate.allowLicense = NO;
        [primary performClick:nil];
        Require(delegate.licenseViews == 1 && store.preparations == 0 &&
            ![defaults boolForKey:@"modelLicenseNoticeShown20261109"] &&
            ![defaults boolForKey:@"firstLaunchShown"],
            @"Declining model setup must leave the license notice and first-run state pending without I/O");
        delegate.allowLicense = YES;
        [primary performClick:nil];
        Require(delegate.licenseViews == 2 && store.preparations == 1 && store.revalidations == 0 &&
            [defaults boolForKey:@"modelLicenseNoticeShown20261109"] &&
            [primary.title hasPrefix:@"Set Up Later"] && primary.enabled &&
            ![defaults boolForKey:@"firstLaunchShown"],
            @"Accepting the model notice must begin preparation and move on to the shortcut step, first use still incomplete");
        [window cancelOperation:nil];
        Require(panel.currentPage == BawanPanelPageTranslation && ![defaults boolForKey:@"firstLaunchShown"],
            @"Closing during preparation must return to the translator without finishing onboarding");
        [delegate startInitialSetup];
        Require(store.preparations == 2 && delegate.licenseViews == 2,
            @"Reopening accepted but unfinished setup must resume preparation without showing the notice again");

        [delegate modelFileDidFail:@"The model could not be verified. Try again."];
        Require(primary.enabled && [primary.title localizedCaseInsensitiveContainsString:@"retry"],
            @"A preparation failure must return to the model step with Retry");
        [primary performClick:nil];
        Require(store.preparations == 3 && store.revalidations == 2 && delegate.licenseViews == 2 &&
            RetryItem(delegate).hidden && [primary.title hasPrefix:@"Set Up Later"],
            @"Retry must prepare again and return to the shortcut step without asking for the accepted license");
        SetAvailableModel(delegate);
        Require(primary.enabled && monitor.permissionRequests == 0 &&
            ![defaults boolForKey:@"firstLaunchShown"],
            @"Model readiness must enable Start without requesting either optional OS permission");
        [primary performClick:nil];
        Require(panel.currentPage == BawanPanelPageTranslation && [defaults boolForKey:@"firstLaunchShown"] &&
            [window.contentView.identifier isEqualToString:@"bawan-panel"] &&
            [source.string isEqualToString:edited] && [output.string isEqualToString:@"A saved translation"] &&
            NSEqualRanges(source.selectedRange, NSMakeRange(25, 8)) && source.undoManager.canUndo &&
            std::abs(source.enclosingScrollView.contentView.bounds.origin.y - readingOrigin.y) < 1,
            @"Finishing ready guidance must persist completion and restore text, output, selection, scrolling and Undo");

        [delegate openSettings:nil];
        Require(panel.currentPage == BawanPanelPageSettings &&
            [window.contentView.identifier isEqualToString:@"bawan-settings"] &&
            FindView(window.contentView, @"onboarding-title") == nil,
            @"Everyday Settings must be a separate page, without permanent first-run guidance");
        NSView *settingsContent = window.contentView;
        [delegate openSettings:nil];
        Require(panel.currentPage == BawanPanelPageSettings && window.contentView == settingsContent,
            @"Reopening Settings must retain its selected page and content");
        [window cancelOperation:nil];
        Require(panel.currentPage == BawanPanelPageTranslation &&
            [window.contentView.identifier isEqualToString:@"bawan-panel"] &&
            [source.string isEqualToString:edited] && [output.string isEqualToString:@"A saved translation"],
            @"The shared host must restore the same translator after Settings");
        [source.undoManager undo];
        Require([source.string isEqualToString:@"Original source"], @"Onboarding and Settings must preserve source Undo");
        [source.undoManager redo];
        Require([source.string isEqualToString:edited], @"Onboarding and Settings must preserve source Redo");

        [defaults setBool:NO forKey:@"firstLaunchShown"];
        [delegate showOnboarding];
        [window cancelOperation:nil];
        Require(panel.currentPage == BawanPanelPageTranslation && [defaults boolForKey:@"firstLaunchShown"] &&
            [window.contentView.identifier isEqualToString:@"bawan-panel"] && monitor.permissionRequests == 0,
            @"Escape from ready guidance must finish first use without optional shortcut permissions");
        [defaults setBool:NO forKey:@"firstLaunchShown"];
        [delegate beginModelSetup];
        [delegate modelFileDidProgress:0.4 message:@"Downloading the model… 40%"];
        [delegate showOnboarding];
        NSButton *later = (NSButton *)FindView(window.contentView, @"onboarding-primary");
        Require([later.title hasPrefix:@"Set Up Later"], @"An unset shortcut must offer Set Up Later");
        [later performClick:nil];
        Require(panel.currentPage == BawanPanelPageTranslation && [defaults boolForKey:@"firstLaunchShown"] &&
            [window.contentView.identifier isEqualToString:@"bawan-panel"],
            @"Set Up Later must finish onboarding and open the translator while the model still downloads");
        SetAvailableModel(delegate);
        [defaults setBool:NO forKey:@"firstLaunchShown"];
        [delegate showOnboarding];
        NSUInteger warmUpsBefore = delegate.warmUps;
        [delegate openTranslation:nil];
        Require(panel.currentPage == BawanPanelPageTranslation && [defaults boolForKey:@"firstLaunchShown"] &&
            delegate.warmUps == warmUpsBefore + 1 &&
            [window.contentView.identifier isEqualToString:@"bawan-panel"],
            @"Open Translator must leave ready guidance and prepare the actual translation surface");

        existingUser = [[SetupSmokeDelegate alloc] init];
        existingPanel = [[TranslationPanel alloc] init];
        SetupSmokeStore *existingStore = [[SetupSmokeStore alloc] init];
        [existingUser setValue:defaults forKey:@"defaults"];
        [existingUser setValue:preferences forKey:@"shortcutPreferences"];
        [existingUser setValue:monitor forKey:@"shortcut"];
        [existingUser setValue:existingStore forKey:@"modelStore"];
        [existingUser setValue:existingPanel forKey:@"translationPanel"];
        [existingUser buildMenus];
        [existingUser startInitialSetup];
        Require(existingPanel.currentPage == BawanPanelPageTranslation && !existingPanel.window.visible &&
            existingStore.preparations == 1 && existingStore.revalidations == 0 && existingUser.licenseViews == 0,
            @"Existing users must prepare their model normally without seeing first-run guidance again");
        CheckShortcutStatusPresentation(delegate, panel);
    } @finally {
        [panel close];
        [delegate applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:NSApp]];
        [existingPanel close];
        if (existingUser) [existingUser applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:NSApp]];
        [defaults removePersistentDomainForName:suite];
    }
}

static void CheckModelLicenseSheet(void) {
    NSString *suite = [@"local.bawan.LicenseSheetSmoke." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removePersistentDomainForName:suite];
    ShortcutPreferences *preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
    SetupSmokeMonitor *monitor = [[SetupSmokeMonitor alloc] initWithPreferences:preferences];
    SetupSmokeStore *store = [[SetupSmokeStore alloc] init];
    // A plain AppDelegate keeps the real license presentation.
    AppDelegate *delegate = [[AppDelegate alloc] init];
    TranslationPanel *panel = [[TranslationPanel alloc] init];
    [delegate setValue:defaults forKey:@"defaults"];
    [delegate setValue:preferences forKey:@"shortcutPreferences"];
    [delegate setValue:monitor forKey:@"shortcut"];
    [delegate setValue:store forKey:@"modelStore"];
    [delegate setValue:panel forKey:@"translationPanel"];
    [delegate buildMenus];
    @try {
        [delegate showOnboarding];
        NSWindow *window = panel.window;
        Require(window.visible && panel.currentPage == BawanPanelPageOnboarding,
            @"The license sheet fixture needs the visible onboarding panel");
        [delegate beginModelSetup];
        Require(window.attachedSheet != nil && store.preparations == 0 &&
            ![defaults boolForKey:@"modelLicenseNoticeShown20261109"],
            @"The model license must attach to the panel as a sheet without blocking or preparing the model");
        [delegate openSettings:nil];
        Require(panel.currentPage == BawanPanelPageSettings &&
            window.attachedSheet == nil && store.preparations == 0 &&
            ![defaults boolForKey:@"modelLicenseNoticeShown20261109"],
            @"Leaving the page must dismiss the license sheet as declined");

        [delegate showOnboarding];
        [delegate beginModelSetup];
        Require(window.attachedSheet != nil, @"Setup must show the license sheet again after it was dismissed");
        [window endSheet:window.attachedSheet returnCode:NSAlertFirstButtonReturn];
        Require(window.attachedSheet == nil && store.preparations == 1 &&
            [defaults boolForKey:@"modelLicenseNoticeShown20261109"],
            @"Continuing from the license sheet must record consent and begin preparation");
        [panel close];
        Require(!window.visible && panel.currentPage == BawanPanelPageTranslation &&
            [window.contentView.identifier isEqualToString:@"bawan-panel"],
            @"Closing onboarding must reset the selected page to the translator");
    } @finally {
        if (panel.window.attachedSheet) [panel.window endSheet:panel.window.attachedSheet returnCode:NSModalResponseCancel];
        [panel close];
        [delegate applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:NSApp]];
        [defaults removePersistentDomainForName:suite];
    }
}

int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSString *suite = [@"local.bawan.AppDelegateSmoke." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        [defaults removePersistentDomainForName:suite];
        [defaults setBool:YES forKey:@"firstLaunchShown"];
        [defaults setBool:YES forKey:@"modelLicenseNoticeShown20261109"];
        EngineSmokeDelegate *delegate = [[EngineSmokeDelegate alloc] init];
        SetupSmokeStore *store = [[SetupSmokeStore alloc] init];
        [delegate setValue:store forKey:@"modelStore"];
        [delegate setValue:defaults forKey:@"defaults"];
        TranslationPanel *panel = [[TranslationPanel alloc] init];
        [delegate setValue:panel forKey:@"translationPanel"];
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
                CheckColdRequestAndRetry(delegate, panel);
                CheckWarmUpFailure(delegate, panel);
                CheckModelStatusPresentation(delegate, panel);
                CheckModelRevalidationOnRetry(delegate, store);
                CheckFirstRunIntegration();
                CheckModelLicenseSheet();
                std::cout << "PASS: pending selection cancellation, source edits, stale output isolation, cold load errors, warmup errors, retry isolation, verification stamps, model revalidation, first-run navigation and the license sheet\n";
            } catch (const std::exception &error) {
                std::cerr << "FAIL: " << error.what() << '\n';
                result = EXIT_FAILURE;
            }
        } @finally {
            [panel close];
            [delegate applicationWillTerminate:
                [NSNotification notificationWithName:NSApplicationWillTerminateNotification object:NSApp]];
            [defaults removePersistentDomainForName:suite];
        }
        return result;
    }
}
