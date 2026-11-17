#import "AppDelegate.h"
#import "TranslationPanel.h"
#import "ModelStore.h"
#import "OnboardingViewController.h"
#import "SettingsViewController.h"
#import "BawanAppearance.h"

#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

@interface AppDelegate (SmokeTest)
- (void)buildMenus;
- (void)updateStatus;
- (void)updateShortcutItem;
- (void)translateText:(NSString *)text direction:(bawan::Direction)direction;
- (void)warmUpEngine;
- (void)ensureEngine;
- (void)cancelTranslation;
- (void)cancelTranslationKeepingPendingSelection:(BOOL)keepSelection;
- (void)retryModel:(id)sender;
- (void)handleEngineEvent:(const bawan::EngineEvent &)event;
- (void)handleSelectionText:(NSString *)text;
- (void)modelFileDidProgress:(double)progress message:(NSString *)message;
- (void)modelFileDidBecomeReady:(NSURL *)fileURL;
- (void)modelFileDidFail:(NSString *)message;
- (void)startInitialSetup;
- (void)showOnboarding;
- (void)beginModelSetup;
- (void)finishOnboarding;
- (void)finishOnboardingFromShortcuts;
- (void)openTranslation:(id)sender;
- (void)openSettings:(id)sender;
- (void)requestModelLicenseAcceptance:(void (^)(BOOL accepted))completion;
- (void)shortcutPreferencesDidChange:(NSNotification *)notification;
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
@end

@implementation SetupSmokeDelegate
- (void)requestModelLicenseAcceptance:(void (^)(BOOL accepted))completion {
    ++_licenseViews;
    completion(_allowLicense);
}
- (void)warmUpEngine { ++_warmUps; }
@end

@interface SelectionSetupSmokeDelegate : SmokeAppDelegate
@end

@implementation SelectionSetupSmokeDelegate
- (void)requestModelLicenseAcceptance:(void (^)(BOOL accepted))completion { completion(YES); }
@end

@interface TrialRefreshSmokeDelegate : SelectionSetupSmokeDelegate
@property(nonatomic) NSUInteger cancellations;
@end

@implementation TrialRefreshSmokeDelegate
- (void)cancelTranslationKeepingPendingSelection:(BOOL)keepSelection {
    ++_cancellations;
    [super cancelTranslationKeepingPendingSelection:keepSelection];
}
@end

@interface TrialRefreshSmokeController : OnboardingViewController
@property(nonatomic) NSUInteger refreshes;
@end

@implementation TrialRefreshSmokeController
- (void)refresh {
    ++_refreshes;
    [super refresh];
}
@end

@interface TrialRefreshSmokeSettings : SettingsViewController
@property(nonatomic) NSUInteger refreshes;
@end

@implementation TrialRefreshSmokeSettings
- (void)refresh {
    ++_refreshes;
    [super refresh];
}
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
@property(nonatomic) BOOL selectionAvailable;
@end

@implementation SetupSmokeMonitor
- (void)start {}
- (void)stop {}
- (void)refresh {}
- (ShortcutAvailability)availabilityForAction:(bawan::ShortcutAction)action {
    return action == bawan::ShortcutAction::TranslateSelection ?
        (_selectionAvailable ? ShortcutAvailabilityAvailable : ShortcutAvailabilityNeedsInputMonitoring) :
        ShortcutAvailabilityNeedsAccessibility;
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
    }

    [delegate translateText:@"Cancel loading" direction:bawan::Direction::Automatic];
    [delegate handleEngineEvent:loading];
    [delegate cancelTranslation];
    bawan::EngineEvent cancelled{Kind::Cancelled, 0, {}};
    [delegate handleEngineEvent:cancelled];
    [delegate updateStatus];
    requireStatus(@"Translation cancelled", BawanSecondaryText);
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
    enum class Change { None, ReadyBeforeFinish, ReadyBeforeReplacement, NewSelection, Edit, Cancel, Close };
    for (Change change : {Change::None, Change::ReadyBeforeFinish, Change::ReadyBeforeReplacement,
            Change::NewSelection, Change::Edit, Change::Cancel, Change::Close}) {
        NSString *suite = [@"local.bawan.FirstSelectionSmoke." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        ShortcutPreferences *preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        SetupSmokeMonitor *monitor = [[SetupSmokeMonitor alloc] initWithPreferences:preferences];
        SetupSmokeStore *store = [[SetupSmokeStore alloc] init];
        AppDelegate *delegate = [[SelectionSetupSmokeDelegate alloc] init];
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
            [delegate handleSelectionText:@"The first selected sentence"];
            NSWindow *window = panel.window;
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

static void ServiceQueuedAppEvents(NSWindow *window) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
    unsigned dispatched = 0;
    while ((!NSApp.active || !window.isKeyWindow) && deadline.timeIntervalSinceNow > 0) {
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
            untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]
            inMode:NSDefaultRunLoopMode dequeue:YES];
        if (event) { [NSApp sendEvent:event]; ++dispatched; }
        [window makeKeyWindow];
    }
    std::cerr << "APP EVENTS dispatched=" << dispatched
        << " appActive=" << NSApp.active
        << " runningAppActive=" << NSRunningApplication.currentApplication.active
        << " key=" << window.isKeyWindow << "\n";
}

static void CheckSelectionTrial(void) {
    using Kind = bawan::EngineEvent::Kind;
    enum class Case { Success, Truncated, Empty, Error, Cancelled, Binding, Permission, Revisit,
                      Queued, QueuedInvalidated, Skip, SkipQueuedWithSelection, SkipActiveWithSelection,
                      CallbackNone, CallbackPanelBinding,
                      CallbackSelectionBinding, CallbackPermission };
    for (Case scenario : {Case::Success, Case::Truncated, Case::Empty, Case::Error, Case::Cancelled,
            Case::Binding, Case::Permission, Case::Revisit, Case::Queued, Case::QueuedInvalidated, Case::Skip,
            Case::SkipQueuedWithSelection, Case::SkipActiveWithSelection, Case::CallbackNone, Case::CallbackPanelBinding, Case::CallbackSelectionBinding, Case::CallbackPermission}) {
        const BOOL skipWithSelection = scenario == Case::SkipQueuedWithSelection ||
            scenario == Case::SkipActiveWithSelection;
        const BOOL checkRefreshes = scenario == Case::CallbackPanelBinding || scenario == Case::CallbackSelectionBinding ||
            scenario == Case::CallbackNone || scenario == Case::CallbackPermission;
        NSString *suite = [@"local.bawan.SelectionTrialSmoke." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        [defaults setBool:YES forKey:@"modelLicenseNoticeShown20261109"];
        ShortcutPreferences *preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        SetupSmokeMonitor *monitor = [[SetupSmokeMonitor alloc] initWithPreferences:preferences];
        monitor.selectionAvailable = YES;
        SetupSmokeStore *store = [[SetupSmokeStore alloc] init];
        SelectionSetupSmokeDelegate *delegate = checkRefreshes ? [[TrialRefreshSmokeDelegate alloc] init] :
            [[SelectionSetupSmokeDelegate alloc] init];
        TrialRefreshSmokeController *refreshOnboarding = nil;
        TrialRefreshSmokeSettings *refreshSettings = nil;
        if (checkRefreshes) {
            refreshOnboarding = [[TrialRefreshSmokeController alloc] initWithPreferences:preferences monitor:monitor];
            refreshSettings = [[TrialRefreshSmokeSettings alloc] initWithPreferences:preferences monitor:monitor];
            [delegate setValue:refreshOnboarding forKey:@"onboardingViewController"];
            [delegate setValue:refreshSettings forKey:@"settingsViewController"];
        }
        TranslationPanel *panel = [[TranslationPanel alloc] init];
        // Programmatic fixture actions have no mouse hit to request panel keyboard focus.
        ((NSPanel *)panel.window).becomesKeyOnlyIfNeeded = NO;
        [delegate setValue:defaults forKey:@"defaults"];
        [delegate setValue:preferences forKey:@"shortcutPreferences"];
        [delegate setValue:monitor forKey:@"shortcut"];
        [delegate setValue:store forKey:@"modelStore"];
        [delegate setValue:panel forKey:@"translationPanel"];
        [delegate buildMenus];
        __weak AppDelegate *weakDelegate = delegate;
        panel.onCancel = ^{ [weakDelegate cancelTranslation]; };
        panel.onClose = ^{ [weakDelegate cancelTranslation]; };
        if (checkRefreshes) {
            refreshOnboarding.onFinish = ^{ [weakDelegate finishOnboardingFromShortcuts]; };
            monitor.onAvailabilityChanged = ^{ [weakDelegate updateShortcutItem]; };
        }
        std::unique_ptr<ScopedEngineCallbackSuppression> callbacks;
        @try {
            [panel showForSelection:@"Previous source"];
            NSTextView *source = (NSTextView *)FindView(panel.window.contentView, @"source");
            NSTextView *output = (NSTextView *)FindView(panel.window.contentView, @"output");
            if (skipWithSelection) [delegate handleSelectionText:@"A selection from another app"];
            [delegate startInitialSetup];
            const BOOL queued = scenario == Case::Queued || scenario == Case::QueuedInvalidated ||
                skipWithSelection || checkRefreshes;
            if (!queued) {
                SetAvailableModel(delegate);
                callbacks = std::make_unique<ScopedEngineCallbackSuppression>(delegate);
            }
            NSWindow *window = panel.window;
            OnboardingViewController *onboarding = [delegate valueForKey:@"onboardingViewController"];
            NSTextView *sample = (NSTextView *)FindView(window.contentView, @"onboarding-trial-sample");
            NSButton *primary = (NSButton *)FindView(window.contentView, @"onboarding-primary");
            NSTextField *trialStatus = (NSTextField *)FindView(window.contentView, @"onboarding-trial-status");
            Require(sample && primary && trialStatus && !sample.hiddenOrHasHiddenAncestor,
                @"An available selection shortcut must offer its sample even if Open Translator needs permission");
            ServiceQueuedAppEvents(window);
            [onboarding setActive:YES];
            BOOL acceptedFocus = [window makeFirstResponder:sample];
            [window makeKeyWindow];
            sample.selectedRange = NSMakeRange(0, sample.string.length);
            Require(acceptedFocus && window.canBecomeKeyWindow && window.visible && window.isKeyWindow &&
                NSApp.keyWindow == window && window.firstResponder == sample,
                [NSString stringWithFormat:@"Selection-trial fixture cannot own keyboard focus: acceptedFocus=%d canKey=%d visible=%d key=%d appKey=%@ active=%d running=%d policy=%ld menu=%@ responder=%@ sampleAcceptsFocus=%d sampleNeedsKey=%d panelKeyOnlyIfNeeded=%d",
                    acceptedFocus, window.canBecomeKeyWindow, window.visible, window.isKeyWindow, NSApp.keyWindow,
                    NSApp.active, NSApp.running, (long)NSApp.activationPolicy, NSApp.mainMenu, window.firstResponder,
                    sample.acceptsFirstResponder, sample.needsPanelToBecomeKey,
                    ((NSPanel *)window).becomesKeyOnlyIfNeeded]);
            Require([primary.title hasPrefix:@"Set Up Later"] && !onboarding.selectionTrialComplete &&
                ![defaults boolForKey:@"firstLaunchShown"],
                @"Selecting the practice sentence and enabling permissions must not complete the trial or onboarding");
            [delegate handleSelectionText:sample.string];
            uint64_t request = [[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue];
            Require(Flag(delegate, @"busy") && !onboarding.selectionTrialComplete &&
                [window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
                [primary.title hasPrefix:@"Set Up Later"] && ![defaults boolForKey:@"firstLaunchShown"],
                @"A real sample callback must start translation while keeping unfinished onboarding visible");
            [delegate handleSelectionText:sample.string];
            Require([[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue] == request,
                @"A duplicate sample callback must not replace or replay a pending trial");
            if (skipWithSelection) {
                uint64_t trialRequest = 0;
                if (scenario == Case::SkipActiveWithSelection) {
                    SetAvailableModel(delegate);
                    callbacks = std::make_unique<ScopedEngineCallbackSuppression>(delegate);
                    trialRequest = [[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue];
                    Require(trialRequest != 0 && ![defaults boolForKey:@"firstLaunchShown"] &&
                        [window.contentView.identifier isEqualToString:@"bawan-onboarding"],
                        @"Readiness must start the practice request without finishing guidance");
                }
                [primary performClick:nil];
                if (scenario == Case::SkipQueuedWithSelection) {
                    Require([[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue] == 0,
                        @"Skipping before readiness must not start inference");
                    SetAvailableModel(delegate);
                    callbacks = std::make_unique<ScopedEngineCallbackSuppression>(delegate);
                }
                const uint64_t ordinaryRequest = [[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue];
                Require([defaults boolForKey:@"firstLaunchShown"] &&
                    [window.contentView.identifier isEqualToString:@"bawan-panel"] &&
                    [source.string isEqualToString:@"A selection from another app"] &&
                    ordinaryRequest != 0 && ordinaryRequest != trialRequest,
                    @"Skipping a practice trial must submit the original external selection once the model is ready");
                if (trialRequest) {
                    bawan::EngineEvent stale{Kind::Complete, trialRequest, "Late practice output", false,
                        bawan::Direction::EnglishToJapanese};
                    [delegate handleEngineEvent:stale];
                    Require(output.string.length == 0 && !onboarding.selectionTrialComplete,
                        @"A skipped trial must not overwrite the ordinary translation with a late result");
                }
                SetAvailableModel(delegate);
                Require([[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue] == ordinaryRequest,
                    @"Duplicate readiness must not submit the ordinary selection again");
                bawan::EngineEvent complete{Kind::Complete, ordinaryRequest, "External selection translated", false,
                    bawan::Direction::EnglishToJapanese};
                [delegate handleEngineEvent:complete];
                Require([output.string isEqualToString:@"External selection translated"],
                    @"The original external selection's result must appear in the translator");
                continue;
            }
            if (queued) {
                Require(request == 0 && [[delegate valueForKey:@"pendingTrialText"] isEqualToString:sample.string],
                    @"A trial during preparation must retain its selected sample until the model is ready");
                if (checkRefreshes) {
                    const NSUInteger attempt = [[delegate valueForKey:@"selectionTrialAttempt"] unsignedIntegerValue];
                    Require(attempt && [onboarding isSelectionTrialCurrent:attempt] &&
                        [[delegate valueForKey:@"engineGeneration"] unsignedLongLongValue] == 0,
                        @"The state callback fixture must own a live queued trial before inference starts");
                    refreshOnboarding.refreshes = 0;
                    refreshSettings.refreshes = 0;
                    TrialRefreshSmokeDelegate *countingDelegate = (TrialRefreshSmokeDelegate *)delegate;
                    countingDelegate.cancellations = 0;
                    if (scenario == Case::CallbackPermission) {
                        monitor.selectionAvailable = NO;
                    } else if (scenario != Case::CallbackNone) {
                        const auto action = scenario == Case::CallbackPanelBinding ? bawan::ShortcutAction::OpenPanel :
                            bawan::ShortcutAction::TranslateSelection;
                        auto binding = [preferences bindingForAction:action];
                        binding.pressCount = 1;
                        NSString *error = nil;
                        Require([preferences setBinding:binding forAction:action error:&error],
                            @"The state callback fixture must apply its requested shortcut change");
                    }
                    Require(monitor.onAvailabilityChanged != nil, @"The legacy availability callback must be installed");
                    monitor.onAvailabilityChanged();
                    const BOOL keepTrial = scenario == Case::CallbackNone || scenario == Case::CallbackPanelBinding;
                    Require(refreshOnboarding.refreshes == 1 && refreshSettings.refreshes == 1 &&
                        countingDelegate.cancellations == (keepTrial ? 0u : 1u),
                        [NSString stringWithFormat:@"One shortcut state callback must refresh onboarding and Settings once, cancelling only an invalid trial: case=%d onboarding=%lu settings=%lu cancellations=%lu",
                            (int)scenario, (unsigned long)refreshOnboarding.refreshes,
                            (unsigned long)refreshSettings.refreshes, (unsigned long)countingDelegate.cancellations]);
                    Require(Flag(delegate, @"busy") == keepTrial &&
                        [onboarding isSelectionTrialCurrent:attempt] == keepTrial &&
                        [[delegate valueForKey:@"selectionTrialAttempt"] unsignedIntegerValue] == (keepTrial ? attempt : 0) &&
                        ![defaults boolForKey:@"firstLaunchShown"] && !onboarding.selectionTrialComplete &&
                        [primary.title hasPrefix:@"Set Up Later"],
                        @"Only a change to the selection shortcut may invalidate its queued trial; no state callback may finish onboarding");
                    if (keepTrial) {
                        Require([[delegate valueForKey:@"pendingTrialText"] isEqualToString:sample.string],
                            @"Unchanged selection state must preserve the queued practice sentence");
                    } else {
                        Require([delegate valueForKey:@"pendingTrialText"] == nil &&
                            ![onboarding finishSelectionTrial:attempt output:@"Late state callback output"
                                direction:bawan::Direction::EnglishToJapanese] && !onboarding.selectionTrialComplete,
                            @"Cancelling an invalid trial must clear its queue and reject the old result");
                        const BOOL hiddenTrial = scenario != Case::CallbackSelectionBinding;
                        Require(sample.hiddenOrHasHiddenAncestor == hiddenTrial &&
                            (hiddenTrial ? monitor.selectionTrialView == nil : monitor.selectionTrialView == sample),
                            @"The same callback must update practice visibility and monitor ownership for the new selection state");
                        if (!hiddenTrial) {
                            NSTextField *instructions = (NSTextField *)FindView(window.contentView, @"onboarding-trial-instructions");
                            Require([instructions.stringValue containsString:@"once"],
                                @"A changed selection binding must update the practice instructions in that refresh");
                        }
                        SetAvailableModel(delegate);
                        Require(!Flag(delegate, @"busy") && [delegate valueForKey:@"pendingTrialText"] == nil &&
                            [[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue] == 0 &&
                            [[delegate valueForKey:@"engineGeneration"] unsignedLongLongValue] == 0,
                            @"Later model readiness must not submit a trial invalidated by a shortcut state callback");
                        continue;
                    }
                }
                if (scenario == Case::QueuedInvalidated) {
                    [onboarding setActive:NO];
                    [onboarding setActive:YES];
                }
                SetAvailableModel(delegate);
                if (scenario == Case::QueuedInvalidated) {
                    Require(!Flag(delegate, @"busy") && [delegate valueForKey:@"pendingTrialText"] == nil &&
                        [[delegate valueForKey:@"engineGeneration"] unsignedLongLongValue] == 0 &&
                        !onboarding.selectionTrialComplete && [primary.title hasPrefix:@"Set Up Later"],
                        @"A page departure must discard a queued trial before model readiness can submit it");
                    continue;
                }
                callbacks = std::make_unique<ScopedEngineCallbackSuppression>(delegate);
                request = [[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue];
                Require(request != 0 && [delegate valueForKey:@"pendingTrialText"] == nil,
                    @"Model readiness must submit the surviving trial without leaving onboarding");
            }
            Require(request != 0, @"The practice fixture must start a real engine request");
            bawan::EngineEvent wrong{Kind::Complete, request + 1, "Wrong request output", false,
                bawan::Direction::EnglishToJapanese};
            bawan::EngineEvent partial{Kind::Text, request, "Partial output", false,
                bawan::Direction::EnglishToJapanese};
            bawan::EngineEvent ready{Kind::Ready, 0, {}};
            [delegate handleEngineEvent:wrong];
            [delegate handleEngineEvent:partial];
            [delegate handleEngineEvent:ready];
            Require(!onboarding.selectionTrialComplete && [primary.title hasPrefix:@"Set Up Later"] &&
                [window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
                ![defaults boolForKey:@"firstLaunchShown"],
                @"A different request, partial output and model readiness must never count as a successful trial");
            if (scenario == Case::Binding) {
                auto binding = [preferences bindingForAction:bawan::ShortcutAction::TranslateSelection];
                binding.keyCode = 2;
                binding.modifiers = bawan::Option;
                NSString *error = nil;
                Require([preferences setBinding:binding forAction:bawan::ShortcutAction::TranslateSelection error:&error],
                    @"The trial's selection binding must be changeable during inference");
                [delegate shortcutPreferencesDidChange:nil];
            } else if (scenario == Case::Permission) {
                monitor.selectionAvailable = NO;
                [delegate applicationDidBecomeActive:[NSNotification
                    notificationWithName:NSApplicationDidBecomeActiveNotification object:NSApp]];
            } else if (scenario == Case::Revisit) {
                [panel showForManualInput];
                [delegate showOnboarding];
            } else if (scenario == Case::Skip) {
                [primary performClick:nil];
            }
            const BOOL success = scenario == Case::Success || scenario == Case::Queued ||
                scenario == Case::CallbackNone || scenario == Case::CallbackPanelBinding;
            const BOOL terminalFailure = scenario == Case::Truncated || scenario == Case::Empty ||
                scenario == Case::Error || scenario == Case::Cancelled;
            Kind kind = scenario == Case::Error ? Kind::Error :
                scenario == Case::Cancelled ? Kind::Cancelled : Kind::Complete;
            std::string result = scenario == Case::Empty ? " \n" : "小さな一歩が、新しい世界を開く。";
            bawan::EngineEvent terminal{kind, request, result, scenario == Case::Truncated,
                bawan::Direction::EnglishToJapanese};
            [delegate handleEngineEvent:terminal];
            if (!success) {
                Require(!onboarding.selectionTrialComplete && !Flag(delegate, @"busy") &&
                    (scenario == Case::Skip || [primary.title hasPrefix:@"Set Up Later"]),
                    @"Failed, truncated, empty, invalidated and skipped trials must never show completion");
                Require([defaults boolForKey:@"firstLaunchShown"] == (scenario == Case::Skip),
                    @"Only explicitly skipping the trial may finish onboarding without a successful translation");
                if (terminalFailure) {
                    Require(!trialStatus.hidden && trialStatus.stringValue.length,
                        @"A failed practice translation must explain that the shortcut can be tried again");
                }
                continue;
            }
            Require(onboarding.selectionTrialComplete && [primary.title hasPrefix:@"Start Translating"] &&
                !trialStatus.hidden && [window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
                ![defaults boolForKey:@"firstLaunchShown"] && !Flag(delegate, @"busy"),
                @"Only the exact successful request may complete the trial; Finish remains an explicit user action");
            [delegate handleEngineEvent:terminal];
            [delegate handleSelectionText:sample.string];
            Require([[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue] == 0,
                @"Repeated completion and sample triggers must not replay a successful trial");
            [primary performClick:nil];
            NSButton *swap = (NSButton *)FindView(window.contentView, @"swap");
            Require([defaults boolForKey:@"firstLaunchShown"] &&
                [window.contentView.identifier isEqualToString:@"bawan-panel"] &&
                [source.string isEqualToString:sample.string] &&
                [output.string isEqualToString:@"小さな一歩が、新しい世界を開く。"] && swap.enabled,
                @"Start Translating must hand the exact practice source and completed result to the real translator");
            __block bawan::Direction reversed = bawan::Direction::Automatic;
            panel.onTranslate = ^(NSString *, bawan::Direction direction) { reversed = direction; };
            [swap performClick:nil];
            Require(reversed == bawan::Direction::JapaneseToEnglish,
                @"The handed-off result must retain its resolved direction for Swap");
        } @finally {
            callbacks.reset();
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
        [panel showForManualInput];
        NSWindow *window = [panel valueForKey:@"panel"];
        NSTextView *source = (NSTextView *)FindView(window.contentView, @"source");
        NSTextView *output = (NSTextView *)FindView(window.contentView, @"output");
        Require(source && output, @"The first-run integration must use the real translator controls");
        [delegate handleSelectionText:@"A selection waiting for setup"];
        Require([window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
            Flag(delegate, @"busy") &&
            [[delegate valueForKey:@"pendingText"] isEqualToString:@"A selection waiting for setup"] &&
            store.preparations == 0 && delegate.licenseViews == 0,
            @"A selection before model consent must queue for translation and show setup without starting preparation");
        [panel showForManualInput];
        Require([source.string isEqualToString:@"A selection waiting for setup"],
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
        Require([window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
            store.preparations == 0 && delegate.licenseViews == 0 &&
            ![defaults boolForKey:@"firstLaunchShown"],
            @"First launch must show guidance without downloading, showing a modal license, or marking it complete");
        Require(window.undoManager == nil, @"The onboarding page must isolate the translator's undo history");
        NSInteger pasteboardCount = NSPasteboard.generalPasteboard.changeCount;
        [window performKeyEquivalent:SetupKey(window, @"\r", NSEventModifierFlagCommand, 36)];
        [window performKeyEquivalent:SetupKey(window, @"c", NSEventModifierFlagCommand | NSEventModifierFlagShift, 8)];
        Require(translations == 0 && NSPasteboard.generalPasteboard.changeCount == pasteboardCount &&
            delegate.licenseViews == 1 && store.preparations == 0,
            @"While onboarding is visible, ⌘Return must mean Download (asking for the license) and never Translate or Copy");
        delegate.licenseViews = 0;
        [window cancelOperation:nil];
        Require(!window.visible && ![defaults boolForKey:@"firstLaunchShown"],
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
        Require(![defaults boolForKey:@"firstLaunchShown"], @"Closing during preparation must not finish onboarding");
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
        Require([defaults boolForKey:@"firstLaunchShown"] &&
            [window.contentView.identifier isEqualToString:@"bawan-panel"] &&
            [source.string isEqualToString:edited] && [output.string isEqualToString:@"A saved translation"] &&
            NSEqualRanges(source.selectedRange, NSMakeRange(25, 8)) && source.undoManager.canUndo &&
            std::abs(source.enclosingScrollView.contentView.bounds.origin.y - readingOrigin.y) < 1,
            @"Finishing ready guidance must persist completion and restore text, output, selection, scrolling and Undo");

        [delegate openSettings:nil];
        Require([window.contentView.identifier isEqualToString:@"bawan-settings"] &&
            FindView(window.contentView, @"onboarding-title") == nil,
            @"Everyday Settings must be a separate page, without permanent first-run guidance");
        [window cancelOperation:nil];
        Require([window.contentView.identifier isEqualToString:@"bawan-panel"] &&
            [source.string isEqualToString:edited] && [output.string isEqualToString:@"A saved translation"],
            @"The shared host must restore the same translator after Settings");
        [source.undoManager undo];
        Require([source.string isEqualToString:@"Original source"], @"Onboarding and Settings must preserve source Undo");
        [source.undoManager redo];
        Require([source.string isEqualToString:edited], @"Onboarding and Settings must preserve source Redo");

        [defaults setBool:NO forKey:@"firstLaunchShown"];
        [delegate showOnboarding];
        [window cancelOperation:nil];
        Require([defaults boolForKey:@"firstLaunchShown"] &&
            [window.contentView.identifier isEqualToString:@"bawan-panel"] && monitor.permissionRequests == 0,
            @"Escape from ready guidance must finish first use without optional shortcut permissions");
        [defaults setBool:NO forKey:@"firstLaunchShown"];
        [delegate beginModelSetup];
        [delegate modelFileDidProgress:0.4 message:@"Downloading the model… 40%"];
        [delegate showOnboarding];
        NSButton *later = (NSButton *)FindView(window.contentView, @"onboarding-primary");
        Require([later.title hasPrefix:@"Set Up Later"], @"An unset shortcut must offer Set Up Later");
        [later performClick:nil];
        Require([defaults boolForKey:@"firstLaunchShown"] &&
            [window.contentView.identifier isEqualToString:@"bawan-panel"],
            @"Set Up Later must finish onboarding and open the translator while the model still downloads");
        SetAvailableModel(delegate);
        [defaults setBool:NO forKey:@"firstLaunchShown"];
        [delegate showOnboarding];
        NSUInteger warmUpsBefore = delegate.warmUps;
        [delegate openTranslation:nil];
        Require([defaults boolForKey:@"firstLaunchShown"] && delegate.warmUps == warmUpsBefore + 1 &&
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
        Require(window.visible, @"The license sheet fixture needs the visible onboarding panel");
        [delegate beginModelSetup];
        Require(window.attachedSheet != nil && store.preparations == 0 &&
            ![defaults boolForKey:@"modelLicenseNoticeShown20261109"],
            @"The model license must attach to the panel as a sheet without blocking or preparing the model");
        [delegate openSettings:nil];
        Require(window.attachedSheet == nil && store.preparations == 0 &&
            ![defaults boolForKey:@"modelLicenseNoticeShown20261109"],
            @"Leaving the page must dismiss the license sheet as declined");

        [delegate showOnboarding];
        [delegate beginModelSetup];
        Require(window.attachedSheet != nil, @"Setup must show the license sheet again after it was dismissed");
        [window endSheet:window.attachedSheet returnCode:NSAlertFirstButtonReturn];
        Require(window.attachedSheet == nil && store.preparations == 1 &&
            [defaults boolForKey:@"modelLicenseNoticeShown20261109"],
            @"Continuing from the license sheet must record consent and begin preparation");
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
        if (![NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]) {
            std::cerr << "FAIL: AppKit smoke fixture could not use accessory activation policy\n";
            return EXIT_FAILURE;
        }
        [NSApp finishLaunching];
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
        if (argc == 2 && std::string(argv[1]) == "--selection-trial") {
            try {
                CheckSelectionTrial();
                std::cout << "PASS: onboarding selection trial success, failure, stale requests, changes and result handoff\n";
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
                CheckSelectionTrial();
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
