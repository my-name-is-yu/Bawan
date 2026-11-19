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
#include <string>

@interface AppDelegate (SmokeTest)
- (void)buildMenus;
- (void)updateStatus;
- (void)translateText:(NSString *)text direction:(bawan::Direction)direction;
- (void)warmUpEngine;
- (void)ensureEngine;
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
- (void)refreshSettings;
- (void)requestModelLicenseAcceptance:(void (^)(BOOL accepted))completion;
@end

@interface SmokeAppDelegate : AppDelegate
@end

@implementation SmokeAppDelegate
- (void)buildMenus {
    // Exercise menu presentation without registering a system status item.
    for (NSString *key in @[@"modelItem", @"retryItem", @"shortcutItem", @"panelShortcutItem"]) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:NULL keyEquivalent:@""];
        [self setValue:item forKey:key];
    }
    [[self valueForKey:@"shortcutItem"] setTag:static_cast<NSInteger>(bawan::ShortcutAction::TranslateSelection)];
    [[self valueForKey:@"panelShortcutItem"] setTag:static_cast<NSInteger>(bawan::ShortcutAction::OpenPanel)];
}
@end

@interface SetupSmokeDelegate : SmokeAppDelegate
@property(nonatomic) BOOL allowLicense;
@property(nonatomic) NSUInteger licenseViews;
@property(nonatomic) NSUInteger warmUps;
@property(nonatomic) NSUInteger settingsRefreshes;
@end

@implementation SetupSmokeDelegate
- (void)requestModelLicenseAcceptance:(void (^)(BOOL accepted))completion {
    ++_licenseViews;
    completion(_allowLicense);
}
- (void)warmUpEngine { ++_warmUps; }
- (void)refreshSettings {
    ++_settingsRefreshes;
    [super refreshSettings];
}
@end

@interface SelectionSetupSmokeDelegate : SmokeAppDelegate
@end

@implementation SelectionSetupSmokeDelegate
- (void)requestModelLicenseAcceptance:(void (^)(BOOL accepted))completion { completion(YES); }
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

static BOOL Flag(AppDelegate *delegate, NSString *key) {
    return [[delegate valueForKey:key] boolValue];
}

class ScopedEngineCallbackSuppression final {
public:
    explicit ScopedEngineCallbackSuppression(AppDelegate *delegate) : delegate_(delegate) {
        [delegate_ ensureEngine];
        generation_ = [[delegate_ valueForKey:@"engineGeneration"] unsignedLongLongValue];
        [delegate_ setValue:@(generation_ + 1) forKey:@"engineGeneration"];
    }

    ~ScopedEngineCallbackSuppression() {
        [delegate_ setValue:@(generation_) forKey:@"engineGeneration"];
    }

    ScopedEngineCallbackSuppression(const ScopedEngineCallbackSuppression &) = delete;
    ScopedEngineCallbackSuppression &operator=(const ScopedEngineCallbackSuppression &) = delete;

private:
    AppDelegate *__strong delegate_;
    uint64_t generation_;
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

static void SetAvailableModel(AppDelegate *delegate) {
    [delegate modelFileDidBecomeReady:[NSURL fileURLWithPath:@"/__bawan_tests__/missing-model.gguf"]];
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

    ScopedEngineCallbackSuppression callbacks(delegate);
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

    [NSApp sendAction:translate.action to:translate.target from:translate];
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
        !Flag(delegate, @"hasVerifiedModelFile") && [delegate valueForKey:@"modelURL"] == nil &&
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

static void CheckModelStatusPresentation(AppDelegate *delegate, TranslationPanel *panel) {
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
    Require(translate.enabled && !Flag(delegate, @"busy"),
        @"A verified file must enable translation even while preserving the cancellation message");

    ScopedEngineCallbackSuppression callbacks(delegate);
    bawan::EngineEvent loading{Kind::Loading, 0, {}};
    bawan::EngineEvent ready{Kind::Ready, 0, {}};
    bawan::EngineEvent loadError{Kind::Error, 0, "Could not load the verified model"};
    [delegate handleEngineEvent:loading];
    [delegate updateStatus];
    requireStatus(@"Loading the model…", BawanSecondaryText);
    [delegate handleEngineEvent:loadError];
    [delegate updateStatus];
    requireStatus(@"Could not load the verified model", BawanError);
    [delegate handleEngineEvent:ready];
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
        [delegate translateText:@"Try translating" direction:bawan::Direction::Automatic];
        uint64_t request = [[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue];
        Require(request && status.hidden, @"A new request must clear the previous translation outcome");
        [delegate handleEngineEvent:loading];
        [delegate updateStatus];
        requireStatus(@"Loading the model…", BawanSecondaryText);
        [delegate handleEngineEvent:ready];
        Require(status.hidden && Flag(delegate, @"busy") &&
            [[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue] == request,
            @"Model readiness must clear Loading without completing the active translation");
        bawan::EngineEvent terminal{outcome.kind, request, outcome.text, outcome.truncated};
        [delegate handleEngineEvent:terminal];
        [delegate updateStatus];
        requireStatus(outcome.message, outcome.color);
        Require(!Flag(delegate, @"busy"), @"A translation outcome must release the busy state");
        [delegate handleEngineEvent:ready];
        bawan::EngineEvent idleCancellation{Kind::Cancelled, 0, {}};
        [delegate handleEngineEvent:idleCancellation];
        requireStatus(outcome.message, outcome.color);
        [delegate handleEngineEvent:loading];
        requireStatus(@"Loading the model…", BawanSecondaryText);
        [delegate handleEngineEvent:ready];
        Require(status.hidden, @"Ready must clear a model message that took ownership after a translation outcome");
    }

    [delegate translateText:@"Cancel loading" direction:bawan::Direction::Automatic];
    [delegate handleEngineEvent:loading];
    [delegate cancelTranslation];
    bawan::EngineEvent cancelled{Kind::Cancelled, 0, {}};
    [delegate handleEngineEvent:cancelled];
    [delegate updateStatus];
    requireStatus(@"Translation cancelled", BawanSecondaryText);
}

static void CheckShortcutStatusPresentation(AppDelegate *delegate, TranslationPanel *panel) {
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
        [delegate handleEngineEvent:event];
        [delegate updateStatus];
        requireWarning();
    }
    bawan::EngineEvent loading{Kind::Loading, 0, {}};
    bawan::EngineEvent ready{Kind::Ready, 0, {}};
    [delegate handleEngineEvent:loading];
    Require(!status.hidden && [status.stringValue isEqualToString:@"Loading the model…"],
        @"A model load must take ownership from an earlier shortcut warning");
    [delegate handleEngineEvent:ready];
    Require(status.hidden, @"Ready must clear Loading without restoring the superseded shortcut warning");
    [delegate handleEngineEvent:loading];
    [delegate handleShortcutProblem:warning];
    [delegate handleEngineEvent:ready];
    requireWarning();

    ScopedEngineCallbackSuppression callbacks(delegate);
    [delegate translateText:@"Try translating after a shortcut warning" direction:bawan::Direction::Automatic];
    uint64_t request = [[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue];
    Require(request && status.hidden, @"A new translation must clear the shortcut warning");
    bawan::EngineEvent complete{Kind::Complete, request, "Successful translation"};
    [delegate handleEngineEvent:complete];
    [delegate handleEngineEvent:ready];
    Require(status.hidden && !Flag(delegate, @"busy"),
        @"A successful translation must leave no status for a later Ready update to restore");
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

static void CheckFirstRunSelection(void) {
    enum class Change { None, ReadyBeforeFinish, ReadyBeforeReplacement, NewSelection, Edit, Cancel, Close,
                        ExistingUserDeclined };
    for (Change change : {Change::None, Change::ReadyBeforeFinish, Change::ReadyBeforeReplacement,
            Change::NewSelection, Change::Edit, Change::Cancel, Change::Close, Change::ExistingUserDeclined}) {
        NSString *suite = [@"local.bawan.FirstSelectionSmoke." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        ShortcutPreferences *preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        SetupSmokeMonitor *monitor = [[SetupSmokeMonitor alloc] initWithPreferences:preferences];
        SetupSmokeStore *store = [[SetupSmokeStore alloc] init];
        const BOOL existingUser = change == Change::ExistingUserDeclined;
        AppDelegate *delegate = existingUser ? [[SetupSmokeDelegate alloc] init] : [[SelectionSetupSmokeDelegate alloc] init];
        if (existingUser) [defaults setBool:YES forKey:@"firstLaunchShown"];
        TranslationPanel *panel = [[TranslationPanel alloc] init];
        [delegate setValue:defaults forKey:@"defaults"];
        [delegate setValue:preferences forKey:@"shortcutPreferences"];
        [delegate setValue:monitor forKey:@"shortcut"];
        [delegate setValue:store forKey:@"modelStore"];
        [delegate setValue:panel forKey:@"translationPanel"];
        [delegate buildMenus];
        __weak AppDelegate *weakDelegate = delegate;
        panel.onCancel = ^{ [weakDelegate cancelTranslation]; };
        panel.onClose = ^{ [weakDelegate cancelTranslation]; };
        @try {
            [delegate startInitialSetup];
            NSWindow *window = panel.window;
            if (existingUser) {
                [delegate handleSelectionText:@"A selection before model consent"];
                Require([window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
                    !Flag(delegate, @"busy") && [delegate valueForKey:@"pendingText"] == nil &&
                    store.preparations == 0,
                    @"Declining model consent must leave returning users out of the busy state");
                continue;
            }
            [delegate openSettings:nil];
            Require([window.contentView.identifier isEqualToString:@"bawan-settings"],
                @"Settings must open before the first selection");
            [window cancelOperation:nil];
            Require([window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
                ![defaults boolForKey:@"firstLaunchShown"],
                @"Back from Settings must return to unfinished onboarding without a queued selection");
            [delegate handleSelectionText:@"The first selected sentence"];
            Require([window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
                Flag(delegate, @"busy") &&
                [[delegate valueForKey:@"pendingText"] isEqualToString:@"The first selected sentence"] &&
                store.preparations == 0 &&
                [[delegate valueForKey:@"engineGeneration"] unsignedLongLongValue] == 0,
                @"First-run selection must queue before guidance without preparing a model before consent");
            NSString *expectedSource = @"The first selected sentence";
            if (change == Change::NewSelection) {
                expectedSource = @"The latest selected sentence";
                [delegate handleSelectionText:expectedSource];
            } else if (change == Change::Close) {
                [window cancelOperation:nil];
                Require(!window.visible && [delegate valueForKey:@"pendingText"] == nil,
                    @"Closing unfinished guidance must cancel its queued selection");
                [delegate startInitialSetup];
            }
            NSButton *primary = (NSButton *)FindView(window.contentView, @"onboarding-primary");
            [primary performClick:nil];
            Require(store.preparations == 1 && [defaults boolForKey:@"modelLicenseNoticeShown20261109"],
                @"Accepting model setup must start preparation for the queued selection");
            const bool readyBeforeFinish = change == Change::ReadyBeforeFinish ||
                change == Change::ReadyBeforeReplacement;
            if (readyBeforeFinish) {
                for (int readiness = 0; readiness < 2; ++readiness) {
                    SetAvailableModel(delegate);
                    Require(![defaults boolForKey:@"firstLaunchShown"] &&
                        [window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
                        [[delegate valueForKey:@"pendingText"] isEqualToString:expectedSource] &&
                        [[delegate valueForKey:@"engineGeneration"] unsignedLongLongValue] == 0,
                        @"Model readiness must preserve the selection and leave unfinished onboarding open without inference");
                }
            }
            if (change == Change::ReadyBeforeFinish) {
                [delegate openSettings:nil];
                Require([window.contentView.identifier isEqualToString:@"bawan-settings"],
                    @"Settings must open while a selection is waiting for first-run guidance");
                [window cancelOperation:nil];
                Require(![defaults boolForKey:@"firstLaunchShown"] &&
                    [window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
                    [[delegate valueForKey:@"pendingText"] isEqualToString:expectedSource] &&
                    [[delegate valueForKey:@"engineGeneration"] unsignedLongLongValue] == 0,
                    @"Back from Settings must return to unfinished guidance without consuming the selection");
            }
            if (change == Change::ReadyBeforeReplacement) {
                expectedSource = @"A newer selection after the model is ready";
                [delegate handleSelectionText:expectedSource];
                Require(![defaults boolForKey:@"firstLaunchShown"] &&
                    [window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
                    [[delegate valueForKey:@"pendingText"] isEqualToString:expectedSource] &&
                    [[delegate valueForKey:@"engineGeneration"] unsignedLongLongValue] == 0,
                    @"A newer selection must replace the pending text without bypassing unfinished onboarding");
            }
            [primary performClick:nil];
            Require([defaults boolForKey:@"firstLaunchShown"] &&
                [window.contentView.identifier isEqualToString:@"bawan-panel"] &&
                ([[delegate valueForKey:@"engineGeneration"] unsignedLongLongValue] != 0) == readyBeforeFinish,
                @"Finishing guidance must start inference only if the model is already ready");
            NSTextView *source = (NSTextView *)FindView(window.contentView, @"source");
            NSTextView *output = (NSTextView *)FindView(window.contentView, @"output");
            NSButton *translate = (NSButton *)FindView(window.contentView, @"translate");
            Require(source && output && translate && [source.string isEqualToString:expectedSource],
                @"Guidance must restore the latest selected source in the real translator");
            if (change == Change::Edit) {
                expectedSource = @"An edited sentence waiting for an explicit translation";
                [source insertText:expectedSource replacementRange:NSMakeRange(0, source.string.length)];
            } else if (change == Change::Cancel) {
                [translate performClick:nil];
            }
            const BOOL shouldTranslate = change == Change::None || readyBeforeFinish || change == Change::NewSelection;
            if (!readyBeforeFinish) {
                if (shouldTranslate) {
                    Require([[delegate valueForKey:@"pendingText"] isEqualToString:expectedSource],
                        @"Only the latest surviving selection may be submitted when the model becomes ready");
                } else {
                    Require(!Flag(delegate, @"busy") && [delegate valueForKey:@"pendingText"] == nil,
                        @"Editing, cancelling or closing must discard the first-run selection before readiness");
                }
                SetAvailableModel(delegate);
            }
            ScopedEngineCallbackSuppression callbacks(delegate);
            const uint64_t request = [[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue];
            Require((request != 0) == shouldTranslate && Flag(delegate, @"busy") == shouldTranslate &&
                [delegate valueForKey:@"pendingText"] == nil && [source.string isEqualToString:expectedSource] &&
                output.string.length == 0,
                @"Finishing setup and model readiness must submit only the surviving selection and consume the queue");
            SetAvailableModel(delegate);
            Require([[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue] == request,
                @"Repeated readiness must not submit the first-run selection a second time");
            if (shouldTranslate) {
                bawan::EngineEvent complete{bawan::EngineEvent::Kind::Complete, request, "Selected sentence translated",
                    false, bawan::Direction::EnglishToJapanese};
                [delegate handleEngineEvent:complete];
                Require([output.string isEqualToString:@"Selected sentence translated"] && !Flag(delegate, @"busy"),
                    @"The automatic request's completion must display its translation without a manual Translate action");
                SetAvailableModel(delegate);
                Require([[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue] == 0 &&
                    [output.string isEqualToString:@"Selected sentence translated"],
                    @"Later readiness must preserve the completed translation without replaying the selection");
            }
        } @finally {
            [panel close];
            [delegate applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:NSApp]];
            [defaults removePersistentDomainForName:suite];
        }
    }
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
    panel.onCancel = ^{ [weakDelegate cancelTranslation]; };
    panel.onClose = ^{ [weakDelegate cancelTranslation]; };
    __block NSUInteger translations = 0;
    panel.onTranslate = ^(NSString *, bawan::Direction) { ++translations; };
    SetupSmokeDelegate *existingUser = nil;
    TranslationPanel *existingPanel = nil;
    @try {
        Require(panel.currentPage == BawanPanelPageTranslation && !panel.window.visible,
            @"A new hidden panel must select the translator");
        [panel showForManualInput];
        NSWindow *window = [panel valueForKey:@"panel"];
        NSTextView *source = (NSTextView *)FindView(window.contentView, @"source");
        NSTextView *output = (NSTextView *)FindView(window.contentView, @"output");
        Require(source && output, @"The first-run integration must use the real translator controls");
        [delegate handleSelectionText:@"A selection waiting for setup"];
        Require(panel.currentPage == BawanPanelPageOnboarding &&
            [window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
            Flag(delegate, @"busy") &&
            [[delegate valueForKey:@"pendingText"] isEqualToString:@"A selection waiting for setup"] &&
            store.preparations == 0 && delegate.licenseViews == 0,
            @"A selection before model consent must queue for translation and show setup without starting preparation");
        [panel showForManualInput];
        Require(panel.currentPage == BawanPanelPageTranslation &&
            [source.string isEqualToString:@"A selection waiting for setup"],
            @"Returning from unfinished setup must preserve the selected text for later translation");
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
            !Flag(delegate, @"modelFailed") && [primary.title hasPrefix:@"Set Up Later"],
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
        NSNotification *activated = [NSNotification notificationWithName:NSApplicationDidBecomeActiveNotification
            object:NSApp];
        const NSUInteger refreshes = delegate.settingsRefreshes;
        [delegate applicationDidBecomeActive:activated];
        Require(delegate.settingsRefreshes == refreshes + 1, @"Activation must refresh visible Settings");
        [window orderOut:nil];
        Require(panel.currentPage == BawanPanelPageSettings && !window.visible,
            @"Ordering the window out must keep Settings selected");
        [delegate applicationDidBecomeActive:activated];
        Require(delegate.settingsRefreshes == refreshes + 1, @"Activation must leave hidden Settings unchanged");
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
        Require([existingUser valueForKey:@"onboardingViewController"] == nil &&
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
    // Keep the real license presentation.
    AppDelegate *delegate = [[SmokeAppDelegate alloc] init];
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

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        if (argc == 2 && std::string(argv[1]) == "--first-run-selection") {
            try {
                CheckFirstRunSelection();
                std::cout << "PASS: first-run selection translation, replacement, editing, cancellation and no replay\n";
                return EXIT_SUCCESS;
            } catch (const std::exception &error) {
                std::cerr << "FAIL: " << error.what() << '\n';
                return EXIT_FAILURE;
            }
        }
        NSString *suite = [@"local.bawan.AppDelegateSmoke." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        [defaults removePersistentDomainForName:suite];
        [defaults setBool:YES forKey:@"firstLaunchShown"];
        [defaults setBool:YES forKey:@"modelLicenseNoticeShown20261109"];
        AppDelegate *delegate = [[SmokeAppDelegate alloc] init];
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
                CheckColdRequestAndRetry(delegate);
                CheckWarmUpFailure(delegate);
                CheckModelStatusPresentation(delegate, panel);
                CheckModelRevalidationOnRetry(delegate);
                CheckFirstRunSelection();
                CheckFirstRunIntegration();
                CheckModelLicenseSheet();
                std::cout << "PASS: pending selection cancellation, source edits, stale output isolation, cold load errors, warmup errors, retry isolation, verification stamps, model revalidation, first-run selection translation, first-run navigation and the license sheet\n";
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
