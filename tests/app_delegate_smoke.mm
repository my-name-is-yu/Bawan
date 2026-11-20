#import "AppDelegate.h"
#import "ApplicationRunLoop.h"
#import "EngineHost.h"
#import "MemoryProbe.h"
#import "TranslationPanel.h"
#import "AppUpdater.h"
#import "ModelStore.h"
#import "OnboardingViewController.h"
#import "SettingsViewController.h"
#import "BawanAppearance.h"
#import "ShortcutPreferences.h"
#import "SetupPresentation.h"
#if BAWAN_ENABLE_UPDATES
#import <Sparkle/Sparkle.h>

@interface AppUpdater (SmokeTest)
- (BOOL)updater:(nullable id)updater mayPerformUpdateCheck:(SPUUpdateCheck)check error:(NSError **)error;
- (void)updater:(nullable id)updater willInstallUpdate:(nullable id)item;
- (BOOL)updater:(nullable id)updater shouldPostponeRelaunchForUpdate:(nullable id)item
    untilInvokingBlock:(void (^)(void))installHandler;
- (void)updater:(nullable id)updater didAbortWithError:(NSError *)error;
@end
#endif

#include "EngineEventMailbox.h"
#include "TranslationSession.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

using namespace bawan::engine;

@interface AppDelegate (SmokeTest)
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults launchMode:(bawan::LaunchMode)mode;
- (void)buildMenus;
- (void)connectTranslationPanel:(TranslationPanel *)panel;
- (void)connectModelStore:(ModelStore *)store;
- (void)updateStatus;
- (void)updateShortcutItem;
- (void)translateText:(NSString *)text direction:(bawan::Direction)direction;
- (void)warmUpEngine;
- (void)cancelTranslation;
- (void)invalidateSelectionTrial;
- (bawan::TranslationSession &)translationSession;
- (BOOL)busy;
- (void)retryModel:(id)sender;
- (void)performModelAction:(id)sender;
- (void)modelStoreDidChange:(const ModelStoreSnapshot &)snapshot;
- (void)handleEngineEvent:(const bawan::EngineEvent &)event;
- (void)handleSelectionText:(NSString *)text;
- (void)handleSelectionTrialText:(NSString *)text;
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender;
- (void)updaterStateDidChange;
- (NSModalResponse)presentUpdateResultAlert:(NSAlert *)alert;
- (NSPasteboard *)updateResultPasteboard;
- (BOOL)copyUpdateResult:(NSString *)result;
- (void)sendTerminationReply:(BOOL)shouldTerminate;
- (void)handleShortcutProblem:(NSString *)message;
- (void)startInitialSetup;
- (void)showOnboarding;
- (void)beginModelSetup;
- (void)finishOnboardingFromShortcuts;
- (void)openTranslation:(id)sender;
- (void)openSettings:(id)sender;
- (void)refreshSettings;
- (void)requestModelLicenseAcceptance:(void (^)(BOOL accepted))completion;
- (void)shortcutPreferencesDidChange:(NSNotification *)notification;
@end

@interface SmokeAppDelegate : AppDelegate
@property(nonatomic) BOOL suppressEngineCallbacks;
- (void)buildNativeMenus;
- (void)injectEngineEvent:(const bawan::EngineEvent &)event;
@end

@implementation SmokeAppDelegate
- (void)handleEngineEvent:(const bawan::EngineEvent &)event {
    if (!_suppressEngineCallbacks) [super handleEngineEvent:event];
}
- (void)injectEngineEvent:(const bawan::EngineEvent &)event {
    [super handleEngineEvent:event];
}
- (void)buildNativeMenus { [super buildMenus]; }
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

#if BAWAN_ENABLE_UPDATES
@interface UpdateTerminationSmokeDelegate : SmokeAppDelegate
@property(nonatomic, strong) NSMutableArray<NSNumber *> *terminationReplies;
@property(nonatomic, copy) NSString *copiedOutput;
@property(nonatomic, copy) NSModalResponse (^chooseRestart)(NSAlert *);
@end

@implementation UpdateTerminationSmokeDelegate
- (void)sendTerminationReply:(BOOL)shouldTerminate {
    [self.terminationReplies addObject:@(shouldTerminate)];
}
- (NSModalResponse)presentUpdateResultAlert:(NSAlert *)alert {
    return self.chooseRestart ? self.chooseRestart(alert) : NSAlertSecondButtonReturn;
}
- (BOOL)copyUpdateResult:(NSString *)result {
    self.copiedOutput = result;
    return YES;
}
@end

@interface UpdatePracticeController : OnboardingViewController
@property(nonatomic, copy) NSString *practiceText;
@end

@implementation UpdatePracticeController
- (BOOL)beginSelectionTrialForText:(NSString *)text {
    self.practiceText = text;
    return YES;
}
- (NSString *)selectionTrialText { return self.practiceText; }
- (BOOL)finishSelectionTrialWithOutput:(NSString *)output { return output.length > 0; }
@end

static BOOL UpdateTerminationProbePassed;

@interface UpdateTerminationProbeDelegate : SmokeAppDelegate
@property(nonatomic, copy) NSString *expectedOutput;
@property(nonatomic, strong) NSUserDefaults *probeDefaults;
@property(nonatomic, copy) NSString *defaultsSuite;
@property(nonatomic, strong) NSPasteboard *probePasteboard;
@end

@implementation UpdateTerminationProbeDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
}

- (NSPasteboard *)updateResultPasteboard { return self.probePasteboard; }

- (NSModalResponse)presentUpdateResultAlert:(NSAlert *)alert {
    NSTimer *click = [NSTimer timerWithTimeInterval:0.05 repeats:NO block:^(NSTimer *) {
        if (NSApp.modalWindow != alert.window) {
            std::cerr << "FAIL: restart choice was not presented during update termination\n";
            std::exit(EXIT_FAILURE);
        }
        [alert.buttons.firstObject performClick:nil];
    }];
    [NSRunLoop.mainRunLoop addTimer:click forMode:NSModalPanelRunLoopMode];
    return [super presentUpdateResultAlert:alert];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    TranslationPanel *panel = [self valueForKey:@"translationPanel"];
    NSTextView *output = [panel valueForKey:@"output"];
    NSString *copiedOutput = [self.probePasteboard stringForType:NSPasteboardTypeString];
    [self.probePasteboard releaseGlobally];
    if (![output.string isEqualToString:self.expectedOutput] || ![copiedOutput isEqualToString:self.expectedOutput]) {
        std::cerr << "FAIL: termination preceded final output or copying to the pasteboard\n";
        std::cerr.flush();
        std::exit(EXIT_FAILURE);
    }
    UpdateTerminationProbePassed = YES;
    std::cout << "PASS: NSTerminateLater displayed and copied the final translation before termination\n";
    std::cout.flush();
    [self.probeDefaults removePersistentDomainForName:self.defaultsSuite];
    [super applicationWillTerminate:notification];
}
@end
#endif

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

@interface TrialRefreshSmokeDelegate : SelectionSetupSmokeDelegate
@property(nonatomic) NSUInteger cancellations;
@end

@implementation TrialRefreshSmokeDelegate
- (void)invalidateSelectionTrial {
    ++_cancellations;
    [super invalidateSelectionTrial];
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
@property(nonatomic) NSUInteger pauses;
@property(nonatomic) NSUInteger resumes;
@end

@implementation SetupSmokeStore
- (void)emit:(const ModelStoreSnapshot &)snapshot {
    if (self.onChange) self.onChange(snapshot);
}
- (void)prepare {
    ++_preparations;
    [self emit:ModelVerifying{ModelFileKind::Saved}];
}
- (void)revalidate {
    ++_revalidations;
    [self prepare];
}
- (void)pause {
    ++_pauses;
    [self emit:ModelPaused{0.4, true}];
}
- (void)resume {
    ++_resumes;
    [self emit:ModelDownloading{0.4, ModelDownloadStage::Receiving}];
}
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
    explicit ScopedEngineCallbackSuppression(SmokeAppDelegate *delegate)
        : delegate_(delegate), previous_(delegate.suppressEngineCallbacks) {
        delegate_.suppressEngineCallbacks = YES;
    }

    ~ScopedEngineCallbackSuppression() {
        delegate_.suppressEngineCallbacks = previous_;
    }

    ScopedEngineCallbackSuppression(const ScopedEngineCallbackSuppression &) = delete;
    ScopedEngineCallbackSuppression &operator=(const ScopedEngineCallbackSuppression &) = delete;

private:
    SmokeAppDelegate *__strong delegate_;
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

@interface EngineHost (SmokeDelivery)
- (void)deliverEventsFromMailbox:(const std::shared_ptr<bawan::EngineEventMailbox> &)mailbox;
@end

@interface SmokeEngineHost : EngineHost
@end

@implementation SmokeEngineHost {
    BOOL _queuedStaleProgress;
}
- (void)deliverEventsFromMailbox:(const std::shared_ptr<bawan::EngineEventMailbox> &)mailbox {
    if (!_queuedStaleProgress) {
        _queuedStaleProgress = YES;
        mailbox->push(Progress{1, "Undelivered old output", bawan::Direction::EnglishToJapanese});
    }
    [super deliverEventsFromMailbox:mailbox];
}
@end

static void CheckEngineHostReset() {
    const auto direction = bawan::Direction::EnglishToJapanese;
    NSURL *missing = [NSURL fileURLWithPath:@"/__bawan_tests__/missing-model.gguf"];
    __block std::vector<bawan::EngineEvent> events;
    __block std::optional<RequestId> replacementId;
    __block __weak EngineHost *weakHost;
    EngineHost *host = [[SmokeEngineHost alloc] initWithEventHandler:^(const bawan::EngineEvent &event) {
        Require(NSThread.isMainThread, @"EngineHost must deliver on the main thread");
        events.push_back(event);
        if (events.size() == 1) {
            [weakHost stopAndDiscardEvents];
            [weakHost startWithModelURL:missing];
            replacementId = [weakHost translate:"Replacement" direction:direction];
        }
    }];
    weakHost = host;
    Require(![host warmUp], @"A stopped host must decline warm-up");
    Require(![host translate:"Not started" direction:direction], @"A stopped host must reject submissions");
    [host startWithModelURL:missing];
    [host translate:"Old request" direction:direction];
    [host startWithModelURL:missing];
    Require(events.empty(), @"EngineHost delivery must not be synchronous");
    const auto *delivered = &events;
    WaitFor([delivered] { return delivered->size() >= 5; }, @"The fresh engine did not finish after reset");
    Require(events.size() == 5 && replacementId &&
        std::holds_alternative<Loading>(std::get<Lifecycle>(events[0])) &&
        std::holds_alternative<Loading>(std::get<Lifecycle>(events[1])) &&
        std::holds_alternative<Idle>(std::get<Lifecycle>(events[2])) &&
        std::holds_alternative<Failed>(std::get<Lifecycle>(events[3])),
        @"Reset must discard the old generation and deliver the replacement lifecycle in order");
    const auto *finished = std::get_if<Finished>(&events[4]);
    Require(finished && finished->requestId == replacementId && std::holds_alternative<Error>(finished->outcome),
        @"Only the replacement request may reach a terminal outcome after reset");
    NSURL *different = [NSURL fileURLWithPath:@"/__bawan_tests__/different-model.gguf"];
    [host startWithModelURL:different];
    const auto switchedId = [host translate:"Use the new file" direction:direction];
    Require(switchedId == replacementId, @"A different model path must start a new engine generation");
    [host stopAndDiscardEvents];
}

static void SetAvailableModel(AppDelegate *delegate) {
    [delegate modelStoreDidChange:ModelReady{[NSURL fileURLWithPath:@"/__bawan_tests__/missing-model.gguf"]}];
}

static bawan::engine::RequestId ActiveRequestId(AppDelegate *delegate) {
    return [delegate translationSession].activeRequestId().value_or(0);
}

static void RequireModelFailure(AppDelegate *delegate) {
    NSMenuItem *retry = [delegate valueForKey:@"retryItem"];
    NSMenuItem *model = [delegate valueForKey:@"modelItem"];
    NSString *status = [delegate valueForKey:@"modelStatus"];
    Require(Flag(delegate, @"modelFailed") && ![delegate busy] &&
        !retry.hidden && retry.enabled && status.length &&
        [model.title isEqualToString:status] && ![status isEqualToString:@"Loading the model…"],
        @"A model load failure must stop loading and expose Retry Model Setup");
    Require(ActiveRequestId(delegate) == 0,
        @"A failed cold request must release the active request ID");
}

static void CheckPendingSelection(AppDelegate *delegate, TranslationPanel *panel) {
    [panel showForSelection:@"First selection"];
    [delegate translateText:@"First selection" direction:bawan::Direction::Automatic];
    Require([delegate busy] && ![delegate translationSession].activeRequestId(),
        @"Verification must queue the selection without submitting it");
    [delegate warmUpEngine];
    [panel close];
    Require(![delegate busy] && ActiveRequestId(delegate) == 0,
        @"Closing during verification must cancel the queued translation");
}

static void CheckEditedRequests(SmokeAppDelegate *delegate, TranslationPanel *panel) {
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
    Require(![delegate busy] &&
        ActiveRequestId(delegate) == 0 &&
        [source.string isEqualToString:@"Revised queued source"] && output.string.length == 0,
        @"Editing a queued source must discard the pending translation before model readiness");
    SetAvailableModel(delegate);
    Require([translate.title isEqualToString:@"Translate  ⌘↵"] && !copy.enabled && !swap.enabled,
        @"Model availability after an edit must leave the revised source ready for an explicit translation");

    ScopedEngineCallbackSuppression callbacks(delegate);
    [translate performClick:nil];
    bawan::engine::RequestId oldRequest = ActiveRequestId(delegate);
    Require(oldRequest != 0 && [delegate busy], @"The edit fixture must start a real active request");
    Progress partial{oldRequest, "Original partial output", bawan::Direction::EnglishToJapanese};
    [delegate injectEngineEvent:partial];
    Require([output.string isEqualToString:@"Original partial output"] && copy.enabled,
        @"The active request must display partial output before it is edited");
    [source breakUndoCoalescing];
    source.undoManager.groupsByEvent = NO;
    [source.undoManager beginUndoGrouping];
    [source insertText:@"Revised active source" replacementRange:NSMakeRange(0, source.string.length)];
    [source.undoManager endUndoGrouping];
    source.undoManager.groupsByEvent = groupsByEvent;
    Require(![delegate busy] && [source.string isEqualToString:@"Revised active source"] &&
        output.string.length == 0 && !copy.enabled && !swap.enabled,
        @"Editing an active source must cancel translation and remove its partial output");
    [delegate injectEngineEvent:Progress{oldRequest, "Late original output", bawan::Direction::EnglishToJapanese}];
    Finished staleComplete{oldRequest, Complete{"Late original output", false, bawan::Direction::EnglishToJapanese}};
    [delegate injectEngineEvent:staleComplete];
    Require(output.string.length == 0 && !copy.enabled && !swap.enabled && ![delegate busy],
        @"Late text and completion must not restore output for an edited source");
    [source.undoManager undo];
    Require([source.string isEqualToString:@"Revised queued source"] && output.string.length == 0,
        [NSString stringWithFormat:@"Cancelling an active translation must preserve Undo without reviving its output; source=%@, output=%@",
            source.string, output.string]);
    [source.undoManager redo];
    Require([source.string isEqualToString:@"Revised active source"],
        [NSString stringWithFormat:@"Cancellation must preserve source Redo; source=%@", source.string]);

    [NSApp sendAction:translate.action to:translate.target from:translate];
    bawan::engine::RequestId newRequest = ActiveRequestId(delegate);
    Require(newRequest != 0 && newRequest != oldRequest, @"The revised source must start a fresh request");
    [delegate injectEngineEvent:staleComplete];
    Require(output.string.length == 0 && [delegate busy],
        @"An old completion must not finish the revised source's request");
    Finished revisedComplete{newRequest, Complete{"Revised output", false, bawan::Direction::EnglishToJapanese}};
    [delegate injectEngineEvent:revisedComplete];
    Require([output.string isEqualToString:@"Revised output"] && copy.enabled && swap.enabled && ![delegate busy],
        @"The revised source's own completion must still enable Copy and Swap");
}

static void CheckColdRequestAndRetry(SmokeAppDelegate *delegate) {
    SetAvailableModel(delegate);
    [delegate translateText:@"Hello" direction:bawan::Direction::EnglishToJapanese];
    Require([delegate busy], @"A cold translation must enter the cancellable busy state");
    WaitFor([&] { return Flag(delegate, @"modelFailed") && ![delegate busy]; },
        @"Cold model loading did not report its failure to the application");
    RequireModelFailure(delegate);

    [delegate translateText:@"Try again" direction:bawan::Direction::EnglishToJapanese];
    bawan::engine::RequestId oldRequest = ActiveRequestId(delegate);
    [delegate retryModel:nil];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    Finished staleError{oldRequest, Error{"Old request failed"}};
    [delegate injectEngineEvent:staleError];
    NSMenuItem *retry = [delegate valueForKey:@"retryItem"];
    Require(![delegate busy] && !Flag(delegate, @"modelFailed") &&
        !Flag(delegate, @"hasVerifiedModelFile") && [delegate valueForKey:@"modelURL"] == nil &&
        [[delegate valueForKey:@"modelStatus"] isEqualToString:@"Checking the saved model…"] && retry.hidden,
        @"Old engine events must not overwrite model setup after Retry");
}

static void CheckWarmUpFailure(AppDelegate *delegate) {
    SetAvailableModel(delegate);
    [delegate warmUpEngine];
    Require(![delegate busy], @"Manual prewarming must not create a translation request");
    WaitFor([&] { return Flag(delegate, @"modelFailed"); },
        @"Model prewarming did not report its failure to the application");
    RequireModelFailure(delegate);
}

static void CheckModelStatusPresentation(SmokeAppDelegate *delegate, TranslationPanel *panel) {
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
    Require(translate.enabled && ![delegate busy],
        @"A verified file must enable translation even while preserving the cancellation message");

    ScopedEngineCallbackSuppression callbacks(delegate);
    const Lifecycle loading = Loading{};
    const Lifecycle ready = Ready{};
    const Lifecycle loadError = Failed{"Could not load the verified model"};
    [delegate injectEngineEvent:loading];
    [delegate updateStatus];
    requireStatus(@"Loading the model…", BawanSecondaryText);
    [delegate injectEngineEvent:loadError];
    [delegate updateStatus];
    requireStatus(@"Could not load the verified model", BawanError);
    [delegate injectEngineEvent:ready];
    Require(status.hidden, @"Model readiness must clear the preceding model error");

    struct Presentation {
        Outcome result;
        NSString *message;
        BawanColorRole color;
    };
    const Presentation outcomes[] = {
        {Complete{"Partial translation", true, bawan::Direction::EnglishToJapanese},
            @"Output limit reached. The translation is incomplete. Select less text and try again.", BawanWarning},
        {Error{"Inference failed"}, @"Inference failed", BawanError},
        {Cancelled{}, @"Translation cancelled", BawanSecondaryText}
    };
    for (const auto &outcome : outcomes) {
        [delegate translateText:@"Try translating" direction:bawan::Direction::Automatic];
        bawan::engine::RequestId request = ActiveRequestId(delegate);
        Require(request && status.hidden, @"A new request must clear the previous translation outcome");
        [delegate injectEngineEvent:loading];
        [delegate updateStatus];
        requireStatus(@"Loading the model…", BawanSecondaryText);
        [delegate injectEngineEvent:ready];
        Require(status.hidden && [delegate busy] &&
            ActiveRequestId(delegate) == request,
            @"Model readiness must clear Loading without completing the active translation");
        Finished terminal{request, outcome.result};
        [delegate injectEngineEvent:terminal];
        [delegate updateStatus];
        requireStatus(outcome.message, outcome.color);
        Require(![delegate busy], @"A translation outcome must release the busy state");
        [delegate injectEngineEvent:ready];
        const Lifecycle idleCancellation = LoadCancelled{};
        [delegate injectEngineEvent:idleCancellation];
        requireStatus(outcome.message, outcome.color);
        [delegate injectEngineEvent:loading];
        requireStatus(@"Loading the model…", BawanSecondaryText);
        [delegate injectEngineEvent:ready];
        Require(status.hidden, @"Ready must clear a model message that took ownership after a translation outcome");
    }

    [delegate translateText:@"Cancel loading" direction:bawan::Direction::Automatic];
    [delegate injectEngineEvent:loading];
    [delegate cancelTranslation];
    const Lifecycle cancelled = LoadCancelled{};
    [delegate injectEngineEvent:cancelled];
    [delegate updateStatus];
    requireStatus(@"Translation cancelled", BawanSecondaryText);
}

static void CheckShortcutStatusPresentation(SmokeAppDelegate *delegate, TranslationPanel *panel) {
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
    for (const auto &event : {Lifecycle{Ready{}}, Lifecycle{LoadCancelled{}}}) {
        [delegate injectEngineEvent:event];
        [delegate updateStatus];
        requireWarning();
    }
    const Lifecycle loading = Loading{};
    const Lifecycle ready = Ready{};
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
    [delegate translateText:@"Try translating after a shortcut warning" direction:bawan::Direction::Automatic];
    bawan::engine::RequestId request = ActiveRequestId(delegate);
    Require(request && status.hidden, @"A new translation must clear the shortcut warning");
    Finished complete{request, Complete{"Successful translation", false, bawan::Direction::EnglishToJapanese}};
    [delegate injectEngineEvent:complete];
    [delegate injectEngineEvent:ready];
    Require(status.hidden && ![delegate busy],
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
    void (^observe)(const ModelStoreSnapshot &) = ^(const ModelStoreSnapshot &snapshot) {
        if (auto *done = std::get_if<ModelReady>(&snapshot)) {
            ++ready;
            lastReadyURL = done->url;
        } else if (auto *failed = std::get_if<ModelFailed>(&snapshot)) {
            ++errors;
            lastError = BawanModelFailureText(*failed);
        }
    };
    @try {
        Require([files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil],
            @"The model retry fixture directory must be created");
        Require([valid writeToURL:model atomically:YES], @"The valid model fixture must be written");
        [delegate connectModelStore:store];
        store.onChange = observe;
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
        [delegate connectModelStore:previousStore];
        [files removeItemAtURL:files.supportDirectory error:nil];
    }
}

static NSEvent *SetupKey(NSWindow *window, NSString *characters, NSEventModifierFlags modifiers, CGKeyCode keyCode) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:modifiers
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
        characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:keyCode];
}

static void CheckFirstRunSelection(void) {
    enum class Change { None, ReadyBeforeFinish, ReadyBeforeReplacement, NewSelection, FromSettings, Edit, Cancel, Close,
                        ExistingUserDeclined };
    for (Change change : {Change::None, Change::ReadyBeforeFinish, Change::ReadyBeforeReplacement,
            Change::NewSelection, Change::FromSettings, Change::Edit, Change::Cancel, Change::Close, Change::ExistingUserDeclined}) {
        NSString *suite = [@"local.bawan.FirstSelectionSmoke." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        ShortcutPreferences *preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        SetupSmokeMonitor *monitor = [[SetupSmokeMonitor alloc] initWithPreferences:preferences];
        SetupSmokeStore *store = [[SetupSmokeStore alloc] init];
        const BOOL existingUser = change == Change::ExistingUserDeclined;
        if (existingUser) [defaults setBool:YES forKey:@"firstLaunchShown"];
        SmokeAppDelegate *delegate = existingUser ?
            [[SetupSmokeDelegate alloc] initWithDefaults:defaults launchMode:bawan::InteractiveLaunch{}] :
            [[SelectionSetupSmokeDelegate alloc] initWithDefaults:defaults launchMode:bawan::InteractiveLaunch{}];
        TranslationPanel *panel = [[TranslationPanel alloc] init];
        [delegate setValue:preferences forKey:@"shortcutPreferences"];
        [delegate setValue:monitor forKey:@"shortcut"];
        [delegate connectModelStore:store];
        [delegate connectTranslationPanel:panel];
        [delegate buildMenus];
        @try {
            [delegate startInitialSetup];
            NSWindow *window = panel.window;
            if (existingUser) {
                [delegate handleSelectionText:@"A selection before model consent"];
                Require([window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
                    ![delegate busy] &&
                    store.preparations == 0,
                    @"Declining model consent must leave returning users out of the busy state");
                continue;
            }
            const BOOL fromSettings = change == Change::FromSettings;
            if (fromSettings) {
                [panel showForManualInput];
                NSTextView *source = (NSTextView *)FindView(window.contentView, @"source");
                source.string = @"Original draft";
                NSUndoManager *undo = source.undoManager;
                BOOL groupsByEvent = undo.groupsByEvent;
                undo.groupsByEvent = NO;
                [undo beginUndoGrouping];
                [source insertText:@"Edited draft" replacementRange:NSMakeRange(0, source.string.length)];
                [undo endUndoGrouping];
                undo.groupsByEvent = groupsByEvent;
                Require(undo.canUndo, @"The detached-selection fixture must begin with editable history");
            }
            [delegate openSettings:nil];
            Require([window.contentView.identifier isEqualToString:@"bawan-settings"],
                @"Settings must open before the first selection");
            if (!fromSettings) {
                [window cancelOperation:nil];
                Require([window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
                    ![defaults boolForKey:@"firstLaunchShown"],
                    @"Back from Settings must return to unfinished onboarding without a queued selection");
            }
            [delegate handleSelectionText:@"The first selected sentence"];
            Require([window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
                [delegate busy] &&
                store.preparations == 0 &&
                ActiveRequestId(delegate) == 0,
                @"First-run selection must queue before guidance without preparing a model before consent");
            NSString *expectedSource = @"The first selected sentence";
            if (change == Change::NewSelection) {
                [delegate handleShortcutProblem:@"The selected text could not be copied."];
                NSTextField *copyError = (NSTextField *)FindView(window.contentView, @"onboarding-error");
                Require(copyError && !copyError.hiddenOrHasHiddenAncestor,
                    @"A copy failure must show a warning while onboarding");
                expectedSource = @"The latest selected sentence";
                [delegate handleSelectionText:expectedSource];
                Require(copyError.hiddenOrHasHiddenAncestor,
                    @"A successful selection must clear the previous copy warning");
            } else if (change == Change::Close) {
                [window cancelOperation:nil];
                Require(!window.visible && ![delegate busy],
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
                        [delegate busy] &&
                        ActiveRequestId(delegate) == 0,
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
                    [delegate busy] &&
                    ActiveRequestId(delegate) == 0,
                    @"Back from Settings must return to unfinished guidance without consuming the selection");
            }
            if (change == Change::ReadyBeforeReplacement) {
                expectedSource = @"A newer selection after the model is ready";
                [delegate handleSelectionText:expectedSource];
                Require(![defaults boolForKey:@"firstLaunchShown"] &&
                    [window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
                    [delegate busy] &&
                    ActiveRequestId(delegate) == 0,
                    @"A newer selection must replace the pending text without bypassing unfinished onboarding");
            }
            [primary performClick:nil];
            Require([defaults boolForKey:@"firstLaunchShown"] &&
                [window.contentView.identifier isEqualToString:@"bawan-panel"] &&
                (ActiveRequestId(delegate) != 0) == readyBeforeFinish,
                @"Finishing guidance must submit the selection only if the model is already ready");
            NSTextView *source = (NSTextView *)FindView(window.contentView, @"source");
            NSTextView *output = (NSTextView *)FindView(window.contentView, @"output");
            NSButton *translate = (NSButton *)FindView(window.contentView, @"translate");
            Require(source && output && translate && [source.string isEqualToString:expectedSource],
                @"Guidance must restore the latest selected source in the real translator");
            if (fromSettings) {
                Require(!source.undoManager.canUndo && !source.undoManager.canRedo,
                    @"A selection received in Settings must not inherit the previous draft's history");
            }
            if (change == Change::Edit) {
                expectedSource = @"An edited sentence waiting for an explicit translation";
                [source insertText:expectedSource replacementRange:NSMakeRange(0, source.string.length)];
            } else if (change == Change::Cancel) {
                [translate performClick:nil];
            }
            const BOOL shouldTranslate = change == Change::None || readyBeforeFinish || change == Change::NewSelection || fromSettings;
            if (!readyBeforeFinish) {
                if (shouldTranslate) {
                    Require([source.string isEqualToString:expectedSource] && [delegate busy],
                        @"Only the latest surviving selection may be submitted when the model becomes ready");
                } else {
                    Require(![delegate busy],
                        @"Editing, cancelling or closing must discard the first-run selection before readiness");
                }
                SetAvailableModel(delegate);
            }
            ScopedEngineCallbackSuppression callbacks(delegate);
            const bawan::engine::RequestId request = ActiveRequestId(delegate);
            Require((request != 0) == shouldTranslate && [delegate busy] == shouldTranslate &&
                [source.string isEqualToString:expectedSource] &&
                output.string.length == 0,
                @"Finishing setup and model readiness must submit only the surviving selection and consume the queue");
            SetAvailableModel(delegate);
            Require(ActiveRequestId(delegate) == request,
                @"Repeated readiness must not submit the first-run selection a second time");
            if (shouldTranslate) {
                Finished complete{request, Complete{"Selected sentence translated", false,
                    bawan::Direction::EnglishToJapanese}};
                [delegate injectEngineEvent:complete];
                Require([output.string isEqualToString:@"Selected sentence translated"] && ![delegate busy],
                    @"The automatic request's completion must display its translation without a manual Translate action");
                SetAvailableModel(delegate);
                Require(ActiveRequestId(delegate) == 0 &&
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
    enum class Case { Success, LaterExternalSelection, FocusChange, ColdLoadFailure,
                      Truncated, Empty, Error, Cancelled, Binding, Permission, PermissionBeforeRefresh, Revisit,
                      Queued, QueuedInvalidated, Skip, SkipQueuedWithSelection, SkipActiveWithSelection,
                      CallbackNone, CallbackPanelBinding,
                      CallbackSelectionBinding, CallbackPermission, Reopen, StaleReopen, OpenTranslatorAfterClose };
    for (Case scenario : {Case::Success, Case::LaterExternalSelection, Case::FocusChange, Case::ColdLoadFailure,
            Case::Truncated, Case::Empty, Case::Error, Case::Cancelled,
            Case::Binding, Case::Permission, Case::PermissionBeforeRefresh, Case::Revisit, Case::Queued, Case::QueuedInvalidated, Case::Skip,
            Case::SkipQueuedWithSelection, Case::SkipActiveWithSelection, Case::CallbackNone, Case::CallbackPanelBinding,
            Case::CallbackSelectionBinding, Case::CallbackPermission, Case::Reopen, Case::StaleReopen,
            Case::OpenTranslatorAfterClose}) {
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
        SelectionSetupSmokeDelegate *delegate = checkRefreshes ?
            [[TrialRefreshSmokeDelegate alloc] initWithDefaults:defaults launchMode:bawan::InteractiveLaunch{}] :
            [[SelectionSetupSmokeDelegate alloc] initWithDefaults:defaults launchMode:bawan::InteractiveLaunch{}];
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
        [delegate setValue:preferences forKey:@"shortcutPreferences"];
        [delegate setValue:monitor forKey:@"shortcut"];
        [delegate connectModelStore:store];
        [delegate connectTranslationPanel:panel];
        [delegate buildMenus];
        __weak AppDelegate *weakDelegate = delegate;
        if (checkRefreshes) {
            refreshOnboarding.onFinish = ^{ [weakDelegate finishOnboardingFromShortcuts]; };
            monitor.onAvailabilityChanged = ^{ [weakDelegate updateShortcutItem]; };
        }
        std::unique_ptr<ScopedEngineCallbackSuppression> callbacks;
        @try {
            [panel showForSelection:@"Previous source"];
            NSTextView *source = (NSTextView *)FindView(panel.window.contentView, @"source");
            NSTextView *output = (NSTextView *)FindView(panel.window.contentView, @"output");
            NSTextField *status = (NSTextField *)FindView(panel.window.contentView, @"status");
            if (skipWithSelection) [delegate handleSelectionText:@"A selection from another app"];
            [delegate startInitialSetup];
            const BOOL queued = scenario == Case::Queued || scenario == Case::QueuedInvalidated ||
                skipWithSelection || checkRefreshes;
            if (!queued) {
                SetAvailableModel(delegate);
                callbacks = std::make_unique<ScopedEngineCallbackSuppression>(delegate);
            }
            NSWindow *window = panel.window;
            OnboardingViewController *onboarding;
            @autoreleasepool { onboarding = [delegate valueForKey:@"onboardingViewController"]; }
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
            [delegate handleSelectionTrialText:sample.string];
            bawan::engine::RequestId request = ActiveRequestId(delegate);
            Require([delegate busy] && !onboarding.selectionTrialComplete &&
                [window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
                [primary.title hasPrefix:@"Set Up Later"] && ![defaults boolForKey:@"firstLaunchShown"],
                @"A real sample callback must start translation while keeping unfinished onboarding visible");
            [delegate handleSelectionTrialText:sample.string];
            Require(ActiveRequestId(delegate) == request,
                @"A duplicate sample callback must not replace or replay a pending trial");
            if (skipWithSelection) {
                uint64_t trialRequest = 0;
                if (scenario == Case::SkipActiveWithSelection) {
                    SetAvailableModel(delegate);
                    callbacks = std::make_unique<ScopedEngineCallbackSuppression>(delegate);
                    trialRequest = ActiveRequestId(delegate);
                    Require(trialRequest != 0 && ![defaults boolForKey:@"firstLaunchShown"] &&
                        [window.contentView.identifier isEqualToString:@"bawan-onboarding"],
                        @"Readiness must start the practice request without finishing guidance");
                }
                [primary performClick:nil];
                if (scenario == Case::SkipQueuedWithSelection) {
                    Require(ActiveRequestId(delegate) == 0,
                        @"Skipping before readiness must not start inference");
                    SetAvailableModel(delegate);
                    callbacks = std::make_unique<ScopedEngineCallbackSuppression>(delegate);
                }
                const bawan::engine::RequestId ordinaryRequest = ActiveRequestId(delegate);
                Require([defaults boolForKey:@"firstLaunchShown"] &&
                    [window.contentView.identifier isEqualToString:@"bawan-panel"] &&
                    [source.string isEqualToString:@"A selection from another app"] &&
                    ordinaryRequest != 0 && ordinaryRequest != trialRequest,
                    @"Skipping a practice trial must submit the original external selection once the model is ready");
                if (trialRequest) {
                    Finished stale{trialRequest, Complete{"Late practice output", false,
                        bawan::Direction::EnglishToJapanese}};
                    [delegate injectEngineEvent:stale];
                    Require(output.string.length == 0 && !onboarding.selectionTrialComplete,
                        @"A skipped trial must not overwrite the ordinary translation with a late result");
                }
                SetAvailableModel(delegate);
                Require(ActiveRequestId(delegate) == ordinaryRequest,
                    @"Duplicate readiness must not submit the ordinary selection again");
                Finished complete{ordinaryRequest, Complete{"External selection translated", false,
                    bawan::Direction::EnglishToJapanese}};
                [delegate injectEngineEvent:complete];
                Require([output.string isEqualToString:@"External selection translated"],
                    @"The original external selection's result must appear in the translator");
                continue;
            }
            if (queued) {
                Require(request == 0 && [delegate translationSession].phase() == bawan::TranslationSession::Phase::Queued,
                    @"A trial during preparation must retain its selected sample until the model is ready");
                if (checkRefreshes) {
                    Require(!trialStatus.hidden &&
                        ActiveRequestId(delegate) == 0,
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
                    Require([delegate busy] == keepTrial &&
                        trialStatus.hidden == !keepTrial &&
                        ![defaults boolForKey:@"firstLaunchShown"] && !onboarding.selectionTrialComplete &&
                        [primary.title hasPrefix:@"Set Up Later"],
                        @"Only a change to the selection shortcut may invalidate its queued trial; no state callback may finish onboarding");
                    if (keepTrial) {
                        Require([delegate translationSession].phase() == bawan::TranslationSession::Phase::Queued,
                            @"Unchanged selection state must preserve the queued practice sentence");
                    } else {
                        Require(trialStatus.hidden &&
                            ![onboarding finishSelectionTrialWithOutput:@"Late state callback output"] && !onboarding.selectionTrialComplete,
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
                        Require(![delegate busy] &&
                            ActiveRequestId(delegate) == 0,
                            @"Later model readiness must not submit a trial invalidated by a shortcut state callback");
                        continue;
                    }
                }
                if (scenario == Case::QueuedInvalidated) {
                    [panel showForManualInput];
                    [delegate showOnboarding];
                }
                SetAvailableModel(delegate);
                if (scenario == Case::QueuedInvalidated) {
                    Require(![delegate busy] &&
                        ActiveRequestId(delegate) == 0 &&
                        !onboarding.selectionTrialComplete && [primary.title hasPrefix:@"Set Up Later"],
                        @"A page departure must discard a queued trial before model readiness can submit it");
                    continue;
                }
                callbacks = std::make_unique<ScopedEngineCallbackSuppression>(delegate);
                request = ActiveRequestId(delegate);
                Require(request != 0,
                    @"Model readiness must submit the surviving trial without leaving onboarding");
            }
            Require(request != 0, @"The practice fixture must start a real engine request");
            Finished wrong{request + 1, Complete{"Wrong request output", false, bawan::Direction::EnglishToJapanese}};
            Progress partial{request, "Partial output", bawan::Direction::EnglishToJapanese};
            const Lifecycle ready = Ready{};
            [delegate injectEngineEvent:wrong];
            [delegate injectEngineEvent:partial];
            [delegate injectEngineEvent:ready];
            Require(!onboarding.selectionTrialComplete && [primary.title hasPrefix:@"Set Up Later"] &&
                [window.contentView.identifier isEqualToString:@"bawan-onboarding"] &&
                ![defaults boolForKey:@"firstLaunchShown"],
                @"A different request, partial output and model readiness must never count as a successful trial");
            if (scenario == Case::ColdLoadFailure) {
                const Lifecycle loadError = Failed{"Could not load the practice model"};
                const Finished requestError{request, Error{"The practice request did not run"}};
                [delegate injectEngineEvent:loadError];
                [delegate injectEngineEvent:requestError];
                Require(![delegate busy] && !onboarding.selectionTrialComplete &&
                    [status.stringValue isEqualToString:@"Could not load the practice model"],
                    @"A cancelled practice request must leave the model's load error visible");
                continue;
            }
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
                Require(![delegate busy] && ActiveRequestId(delegate) == 0,
                    @"Losing shortcut permission must cancel without waiting for an engine event");
            } else if (scenario == Case::PermissionBeforeRefresh) {
                monitor.selectionAvailable = NO;
                Require([delegate busy] && ActiveRequestId(delegate) == request,
                    @"An unreported permission change must leave the request active until completion");
            } else if (scenario == Case::Revisit) {
                [panel showForManualInput];
                Require(![delegate busy] && status.hidden,
                    @"Leaving the trial page must cancel inference without a translator cancellation message");
                [delegate showOnboarding];
            } else if (scenario == Case::Skip) {
                [primary performClick:nil];
                Require(status.hidden,
                    @"Skipping active practice must not show a translator cancellation message");
            } else if (scenario == Case::FocusChange) {
                [onboarding setActive:NO];
                Require([delegate busy] && monitor.selectionTrialView == nil,
                    @"Losing focus must disarm the shortcut while allowing the current trial to finish");
            }
            const BOOL success = scenario == Case::Success || scenario == Case::Queued ||
                scenario == Case::LaterExternalSelection || scenario == Case::FocusChange ||
                scenario == Case::CallbackNone || scenario == Case::CallbackPanelBinding || scenario == Case::Reopen ||
                scenario == Case::StaleReopen || scenario == Case::OpenTranslatorAfterClose;
            const BOOL terminalFailure = scenario == Case::Truncated || scenario == Case::Empty ||
                scenario == Case::Error || scenario == Case::Cancelled;
            std::string result = scenario == Case::Empty ? " \n" : "小さな一歩が、新しい世界を開く。";
            Outcome outcome = Complete{result, scenario == Case::Truncated, bawan::Direction::EnglishToJapanese};
            if (scenario == Case::Error) outcome = Error{result};
            if (scenario == Case::Cancelled) outcome = Cancelled{};
            Finished terminal{request, std::move(outcome)};
            [delegate injectEngineEvent:terminal];
            if (scenario == Case::PermissionBeforeRefresh) {
                Require(ActiveRequestId(delegate) == 0 && ![delegate busy] &&
                    !onboarding.selectionTrialComplete,
                    @"A stale trial terminal must release the request without showing output");
            }
            if (!success) {
                Require(!onboarding.selectionTrialComplete && ![delegate busy] &&
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
                ![defaults boolForKey:@"firstLaunchShown"] && ![delegate busy],
                @"Only the exact successful request may complete the trial; Finish remains an explicit user action");
            if (scenario == Case::Reopen) {
                OnboardingViewController *closed = onboarding;
                [window close];
                [delegate setValue:nil forKey:@"onboardingViewController"];
                [delegate showOnboarding];
                onboarding = [delegate valueForKey:@"onboardingViewController"];
                Require(onboarding != closed, @"Reopening released onboarding must build a new page");
                primary = (NSButton *)FindView(window.contentView, @"onboarding-primary");
                trialStatus = (NSTextField *)FindView(window.contentView, @"onboarding-trial-status");
                Require(onboarding.selectionTrialComplete && [primary.title hasPrefix:@"Start Translating"] &&
                    !trialStatus.hidden, @"A completed practice must stay complete after closing and reopening onboarding");
            }
            if (scenario == Case::StaleReopen) {
                [window close];
                [delegate setValue:nil forKey:@"onboardingViewController"];
                auto binding = [preferences bindingForAction:bawan::ShortcutAction::TranslateSelection];
                binding.keyCode = 2;
                binding.modifiers = bawan::Option;
                NSString *error = nil;
                Require([preferences setBinding:binding forAction:bawan::ShortcutAction::TranslateSelection error:&error],
                    @"The stale practice fixture must change the selection shortcut");
                [delegate showOnboarding];
                onboarding = [delegate valueForKey:@"onboardingViewController"];
                primary = (NSButton *)FindView(window.contentView, @"onboarding-primary");
                Require(!onboarding.selectionTrialComplete && [primary.title hasPrefix:@"Set Up Later"],
                    @"A practice made with an older shortcut must not come back after reopening onboarding");
                continue;
            }
            if (scenario == Case::FocusChange) [onboarding setActive:YES];
            if (scenario == Case::LaterExternalSelection) {
                // Clipboard selections remain ordinary requests even when the text matches the sample.
                NSString *later = sample.string;
                [delegate handleSelectionText:later];
                Require(!onboarding.selectionTrialComplete && [primary.title hasPrefix:@"Set Up Later"],
                    @"A later external selection must supersede a finished trial");
                [primary performClick:nil];
                const bawan::engine::RequestId ordinaryRequest = ActiveRequestId(delegate);
                Require(ordinaryRequest != 0 && ordinaryRequest != request &&
                    [source.string isEqualToString:later] && output.string.length == 0,
                    @"Finishing setup must submit the later external selection instead of restoring the sample");
                continue;
            }
            [delegate injectEngineEvent:terminal];
            [delegate handleSelectionTrialText:sample.string];
            Require(ActiveRequestId(delegate) == 0,
                @"Repeated completion and sample triggers must not replay a successful trial");
            if (scenario == Case::OpenTranslatorAfterClose) {
                @autoreleasepool {
                    [window close];
                    onboarding = nil;
                    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
                }
                Require([delegate valueForKey:@"onboardingViewController"] == nil,
                    @"Closing onboarding after a trial must release its page");
                [delegate openTranslation:nil];
            } else {
                [primary performClick:nil];
            }
            NSButton *swap = (NSButton *)FindView(window.contentView, @"swap");
            Require([defaults boolForKey:@"firstLaunchShown"] &&
                [window.contentView.identifier isEqualToString:@"bawan-panel"] &&
                [source.string isEqualToString:sample.string] &&
                [output.string isEqualToString:@"小さな一歩が、新しい世界を開く。"] && swap.enabled,
                @"Opening the translator must hand it the exact practice source and completed result");
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
    SetupSmokeDelegate *delegate = [[SetupSmokeDelegate alloc] initWithDefaults:defaults launchMode:bawan::InteractiveLaunch{}];
    TranslationPanel *panel = [[TranslationPanel alloc] init];
    [delegate setValue:preferences forKey:@"shortcutPreferences"];
    [delegate setValue:monitor forKey:@"shortcut"];
    [delegate connectModelStore:store];
    [delegate connectTranslationPanel:panel];
    [delegate buildMenus];
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
            [delegate busy] &&
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
        NSString *copyWarning = @"The selected text could not be copied.";
        [delegate handleShortcutProblem:copyWarning];
        NSTextField *shortcutError = (NSTextField *)FindView(window.contentView, @"onboarding-error");
        Require(panel.currentPage == BawanPanelPageOnboarding && shortcutError &&
            !shortcutError.hiddenOrHasHiddenAncestor && [shortcutError.stringValue isEqualToString:copyWarning],
            @"A copy failure must be visible before downloading the model");
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
        primary = (NSButton *)FindView(window.contentView, @"onboarding-primary");
        shortcutError = (NSTextField *)FindView(window.contentView, @"onboarding-error");
        Require(primary && shortcutError && store.preparations == 2 && delegate.licenseViews == 2,
            @"Reopening accepted but unfinished setup must resume preparation without showing the notice again");

        [delegate modelStoreDidChange:ModelFailed{ModelCheckFailed{ModelCheckIssue::HashMismatch, ModelFileKind::Saved}}];
        Require(primary.enabled && [primary.title localizedCaseInsensitiveContainsString:@"retry"],
            @"A preparation failure must return to the model step with Retry");
        [delegate handleShortcutProblem:@"Unable to copy the current selection."];
        Require(!shortcutError.hiddenOrHasHiddenAncestor &&
            [shortcutError.stringValue isEqualToString:@"Unable to copy the current selection."],
            @"A copy failure must be visible while waiting for a retry");
        [primary performClick:nil];
        Require(store.preparations == 3 && store.revalidations == 2 && delegate.licenseViews == 2 &&
            !Flag(delegate, @"modelFailed") && [primary.title hasPrefix:@"Set Up Later"],
            @"Retry must prepare again and return to the shortcut step without asking for the accepted license");
        SetAvailableModel(delegate);
        Require(primary.enabled && monitor.permissionRequests == 0 &&
            ![defaults boolForKey:@"firstLaunchShown"],
            @"Model readiness must enable Start without requesting either optional OS permission");
        [delegate handleShortcutProblem:copyWarning];
        Require(panel.currentPage == BawanPanelPageOnboarding && ![defaults boolForKey:@"firstLaunchShown"] &&
            shortcutError && !shortcutError.hiddenOrHasHiddenAncestor && [shortcutError.stringValue isEqualToString:copyWarning],
            @"A copy failure must show its warning without opening a translator that cannot accept requests");
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
        [delegate openSettings:nil];
        [window close];
        [delegate openSettings:nil];
        Require(panel.currentPage == BawanPanelPageSettings && window.visible &&
            [window.contentView.identifier isEqualToString:@"bawan-settings"],
            @"Settings must reopen after the panel was closed on it");
        [window cancelOperation:nil];
        Require(panel.currentPage == BawanPanelPageTranslation && [source.string isEqualToString:edited],
            @"Leaving reopened Settings must restore the translator");

        [delegate showOnboarding];
        [window cancelOperation:nil];
        Require(panel.currentPage == BawanPanelPageTranslation && [defaults boolForKey:@"firstLaunchShown"] &&
            [window.contentView.identifier isEqualToString:@"bawan-panel"] && monitor.permissionRequests == 0,
            @"Escape from revisited ready guidance must preserve completion without requesting shortcut permissions");
        [delegate beginModelSetup];
        [delegate modelStoreDidChange:ModelDownloading{0.4, ModelDownloadStage::Receiving}];
        [delegate showOnboarding];
        NSButton *later = (NSButton *)FindView(window.contentView, @"onboarding-primary");
        Require([later.title hasPrefix:@"Set Up Later"], @"An unset shortcut must offer Set Up Later");
        [later performClick:nil];
        Require(panel.currentPage == BawanPanelPageTranslation && [defaults boolForKey:@"firstLaunchShown"] &&
            [window.contentView.identifier isEqualToString:@"bawan-panel"],
            @"Set Up Later must reopen the translator while the model still downloads");
        SetAvailableModel(delegate);
        [delegate showOnboarding];
        NSUInteger warmUpsBefore = delegate.warmUps;
        [delegate openTranslation:nil];
        Require(panel.currentPage == BawanPanelPageTranslation && [defaults boolForKey:@"firstLaunchShown"] &&
            delegate.warmUps == warmUpsBefore + 1 &&
            [window.contentView.identifier isEqualToString:@"bawan-panel"],
            @"Open Translator must leave ready guidance and prepare the actual translation surface");

        existingUser = [[SetupSmokeDelegate alloc] initWithDefaults:defaults launchMode:bawan::InteractiveLaunch{}];
        existingPanel = [[TranslationPanel alloc] init];
        SetupSmokeStore *existingStore = [[SetupSmokeStore alloc] init];
        [existingUser setValue:preferences forKey:@"shortcutPreferences"];
        [existingUser setValue:monitor forKey:@"shortcut"];
        [existingUser connectModelStore:existingStore];
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

static void CheckPageRelease(void) {
    NSString *suite = [@"local.bawan.PageReleaseSmoke." stringByAppendingString:NSUUID.UUID.UUIDString];
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
    [delegate connectModelStore:store];
    [delegate connectTranslationPanel:panel];
    [delegate buildMenus];
    SetAvailableModel(delegate);
    [defaults setBool:YES forKey:@"firstLaunchShown"];
    NSWindow *window = panel.window;
    @try {
        __weak NSViewController *settings = nil;
        @autoreleasepool {
            [delegate openSettings:nil];
            settings = [panel valueForKey:@"page"];
            [window orderOut:nil];
        }
        Require(settings != nil, @"A hidden panel must keep its selected Settings page");
        @autoreleasepool { [delegate openSettings:nil]; }
        @autoreleasepool {
            Require([panel valueForKey:@"page"] == settings, @"Reopening a hidden panel must show the same Settings");
        }
        @autoreleasepool {
            [window cancelOperation:nil];
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        Require(settings == nil, @"Leaving Settings must release it");
        @autoreleasepool {
            [delegate openSettings:nil];
            settings = [panel valueForKey:@"page"];
            [window close];
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        Require(settings == nil, @"Closing the panel on Settings must release it");

        [defaults setBool:NO forKey:@"firstLaunchShown"];
        __weak NSViewController *onboarding = nil;
        @autoreleasepool {
            [delegate showOnboarding];
            onboarding = [panel valueForKey:@"page"];
            [delegate openSettings:nil];
            settings = [panel valueForKey:@"page"];
        }
        Require(onboarding != nil && panel.currentPage == BawanPanelPageSettings,
            @"Settings opened from onboarding must keep the onboarding it returns to");
        [delegate modelStoreDidChange:ModelFailed{ModelIssue::DiskFull}];
        @autoreleasepool {
            [window cancelOperation:nil];
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        @autoreleasepool {
            Require(panel.currentPage == BawanPanelPageOnboarding && [panel valueForKey:@"page"] == onboarding,
                @"Leaving Settings must return to the same onboarding");
        }
        Require(monitor.configurationActive == window.keyWindow,
            @"Releasing Settings must not disarm the onboarding page that replaced it");
        NSTextField *coveredMessage = (NSTextField *)FindView(window.contentView, @"onboarding-model-message");
        Require([coveredMessage.stringValue isEqualToString:BawanModelIssueText(ModelIssue::DiskFull)],
            @"The onboarding page Settings covered must show model changes made meanwhile");
        SetAvailableModel(delegate);
        Require(settings == nil, @"Leaving Settings for onboarding must release Settings");
        @autoreleasepool {
            [window close];
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        Require(onboarding == nil, @"Closing the panel on onboarding must release it");
    } @finally {
        [panel close];
        [delegate applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:NSApp]];
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
    SmokeAppDelegate *delegate = [[SmokeAppDelegate alloc] initWithDefaults:defaults launchMode:bawan::InteractiveLaunch{}];
    TranslationPanel *panel = [[TranslationPanel alloc] init];
    [delegate setValue:preferences forKey:@"shortcutPreferences"];
    [delegate setValue:monitor forKey:@"shortcut"];
    [delegate connectModelStore:store];
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

static void CheckDownloadActions(void) {
    NSString *suite = [@"local.bawan.DownloadActionsSmoke." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removePersistentDomainForName:suite];
    [defaults setBool:YES forKey:@"modelLicenseNoticeShown20261109"];
    ShortcutPreferences *preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
    SetupSmokeMonitor *monitor = [[SetupSmokeMonitor alloc] initWithPreferences:preferences];
    SetupSmokeStore *store = [[SetupSmokeStore alloc] init];
    SetupSmokeDelegate *delegate = [[SetupSmokeDelegate alloc] initWithDefaults:defaults launchMode:bawan::InteractiveLaunch{}];
    TranslationPanel *panel = [[TranslationPanel alloc] init];
    [delegate setValue:preferences forKey:@"shortcutPreferences"];
    [delegate setValue:monitor forKey:@"shortcut"];
    [delegate connectModelStore:store];
    [delegate setValue:panel forKey:@"translationPanel"];
    [delegate buildNativeMenus];
    @try {
        [delegate startInitialSetup];
        Require(store.preparations == 1 && delegate.licenseViews == 0,
            @"Accepted model setup must start once before exercising transfer controls");
        [delegate modelStoreDidChange:ModelDownloading{0.4, ModelDownloadStage::Receiving}];
        NSMenuItem *action = [delegate valueForKey:@"retryItem"];
        NSWindow *window = panel.window;
        NSButton *footerControl = (NSButton *)FindView(window.contentView, @"onboarding-model-control");
        Require(action.enabled && !action.hidden && [action.title isEqualToString:@"Pause Download"] &&
            !footerControl.hiddenOrHasHiddenAncestor && [footerControl.title isEqualToString:@"Pause Download"],
            @"The menu and onboarding footer must offer Pause only while a transfer is downloading");
        Require([NSApp sendAction:action.action to:action.target from:action],
            @"The menu's Pause selector must reach its delegate");
        Require(store.pauses == 1 && store.resumes == 0 && !action.hidden &&
            [action.title isEqualToString:@"Resume Download"] && [footerControl.title isEqualToString:@"Resume Download"] &&
            [[delegate valueForKey:@"modelStatus"] isEqualToString:@"Model download paused. Resume to continue."],
            @"Pausing from the menu must preserve progress and update both controls to Resume");
        [footerControl performClick:nil];
        Require(store.resumes == 1 && store.preparations == 1 && store.revalidations == 0 &&
            [action.title isEqualToString:@"Pause Download"] && !Flag(delegate, @"modelFailed"),
            @"The onboarding footer must resume the existing transfer without starting fresh setup or revalidation");
        [footerControl performClick:nil];
        Require(store.pauses == 2, @"Onboarding Pause must reach the store");
        [delegate openSettings:nil];
        NSButton *settingsAction = (NSButton *)FindView(window.contentView, @"settings-model-setup");
        NSProgressIndicator *settingsProgress = (NSProgressIndicator *)FindView(window.contentView, @"settings-model-progress");
        Require(!settingsAction.hiddenOrHasHiddenAncestor && [settingsAction.title isEqualToString:@"Resume Download"] &&
            !settingsProgress.hidden && std::abs(settingsProgress.doubleValue - 0.4) < 0.001,
            @"Settings opened during pause must expose Resume with the saved progress");
        [settingsAction performClick:nil];
        Require(store.resumes == 2 && [settingsAction.title isEqualToString:@"Pause Download"],
            @"Settings Resume must route to the same active transfer and update its next action");

        [delegate modelStoreDidChange:ModelFailed{ModelInterrupted{@"Connection lost."}, 0.4}];
        Require(Flag(delegate, @"modelFailed") && [action.title isEqualToString:@"Resume Download"] &&
            [settingsAction.title isEqualToString:@"Resume Download"],
            @"A failed transfer with retained bytes must offer Resume in Settings and the menu");
        Require([[delegate valueForKey:@"modelStatus"] isEqualToString:@"Model download interrupted. Connection lost. Resume to continue the download."],
            @"A transfer failure must show its own message");
        [delegate showOnboarding];
        NSButton *primary = (NSButton *)FindView(window.contentView, @"onboarding-primary");
        NSTextField *failure = (NSTextField *)FindView(window.contentView, @"onboarding-model-message");
        Require([primary.title hasPrefix:@"Resume Download"] &&
            [failure.stringValue isEqualToString:@"Model download interrupted. Connection lost. Resume to continue the download."],
            @"Onboarding must show the failed transfer's error and make Resume its primary action");
        [primary performClick:nil];
        Require(store.resumes == 3 && !Flag(delegate, @"modelFailed") &&
            [primary.title hasPrefix:@"Set Up Later"] && delegate.licenseViews == 0,
            @"Resuming a transfer failure must clear the failure and return to optional setup without new consent");

        [delegate modelStoreDidChange:ModelVerifying{ModelFileKind::Download}];
        Require(action.hidden && footerControl.hiddenOrHasHiddenAncestor &&
            !Flag(delegate, @"hasVerifiedModelFile") &&
            [[delegate valueForKey:@"modelStatus"] containsString:@"SHA256"],
            @"Verification must hide transfer controls and keep the file unavailable");
        [delegate performModelAction:nil];
        Require(store.pauses == 2 && store.resumes == 3 && store.preparations == 1,
            @"A stale transfer action during verification must not pause, resume or restart setup");
        [delegate openSettings:nil];
        settingsAction = (NSButton *)FindView(window.contentView, @"settings-model-setup");
        Require(settingsAction && settingsAction.hidden,
            @"Settings must hide the transfer action during verification");

        [delegate modelStoreDidChange:ModelFailed{ModelCheckFailed{ModelCheckIssue::HashMismatch, ModelFileKind::Download}}];
        Require([action.title isEqualToString:@"Retry Model Setup"] && !action.hidden &&
            [settingsAction.title isEqualToString:@"Retry Model Setup"],
            @"Verification failure without retained bytes must offer a fresh Retry instead of Resume");
        SetAvailableModel(delegate);
        Require(action.hidden && settingsAction.hidden && Flag(delegate, @"hasVerifiedModelFile") &&
            !Flag(delegate, @"modelFailed"),
            @"A ready file must clear transfer actions");
    } @finally {
        [panel close];
        [delegate applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:NSApp]];
        [defaults removePersistentDomainForName:suite];
    }
}

#if BAWAN_ENABLE_UPDATES
static void AbortUpdate(AppUpdater *updater) {
    [updater updater:nil didAbortWithError:[NSError errorWithDomain:@"update-test" code:1 userInfo:nil]];
}

static void AttachTestUpdater(AppDelegate *delegate, AppUpdater *updater) {
    [delegate setValue:updater forKey:@"updater"];
    __weak AppDelegate *weakDelegate = delegate;
    updater.onStateChanged = ^{ [weakDelegate updaterStateDidChange]; };
}

static void DrainUpdateEvents(void) {
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
}

static void CheckUpdateWithQueuedSelectionAndPractice(void) {
    const auto direction = bawan::Direction::EnglishToJapanese;
    NSString *suite = [@"local.bawan.UpdatePractice." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    UpdateTerminationSmokeDelegate *delegate = [[UpdateTerminationSmokeDelegate alloc]
        initWithDefaults:defaults launchMode:bawan::InteractiveLaunch{}];
    ScopedEngineCallbackSuppression callbacks(delegate);
    TranslationPanel *panel = [[TranslationPanel alloc] init];
    ShortcutPreferences *preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
    SetupSmokeMonitor *monitor = [[SetupSmokeMonitor alloc] initWithPreferences:preferences];
    UpdatePracticeController *onboarding = [[UpdatePracticeController alloc]
        initWithPreferences:preferences monitor:monitor];
    [delegate setValue:preferences forKey:@"shortcutPreferences"];
    [delegate setValue:monitor forKey:@"shortcut"];
    [delegate setValue:onboarding forKey:@"onboardingViewController"];
    [delegate connectTranslationPanel:panel];
    [delegate buildMenus];
    AppUpdater *updater = [[AppUpdater alloc] init];
    AttachTestUpdater(delegate, updater);

    @try {
        SetAvailableModel(delegate);
        [delegate handleSelectionText:@"Selection kept behind onboarding"];
        Require([delegate busy] && ActiveRequestId(delegate) == 0,
            @"The first-run selection must stay queued while onboarding is open");
        [delegate handleSelectionTrialText:@"Active shortcut practice"];
        const auto practice = ActiveRequestId(delegate);
        __block BOOL restarted = NO;
        Require(practice != 0 && [onboarding.practiceText isEqualToString:@"Active shortcut practice"] &&
            [updater updater:nil shouldPostponeRelaunchForUpdate:nil
            untilInvokingBlock:^{ restarted = YES; }],
            @"An update must wait for the running trial even with a separate selection queued");
        delegate.chooseRestart = ^NSModalResponse(NSAlert *) { return NSAlertFirstButtonReturn; };
        [delegate injectEngineEvent:Finished{practice, Complete{"Completed practice result", false, direction}}];
        Require([delegate busy] && ActiveRequestId(delegate) == 0,
            @"Completing the trial must leave the original selection queued");
        WaitFor(^BOOL { return restarted; }, @"Queued work must not prevent the confirmed restart");
        Require([delegate.copiedOutput isEqualToString:@"Completed practice result"],
            @"Copy and Restart must keep the active trial result rather than the queued selection");
    } @finally {
        [panel close];
        [delegate applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:NSApp]];
        [defaults removePersistentDomainForName:suite];
    }
}

static void CheckUpdateTerminationBehavior(void) {
    const auto direction = bawan::Direction::EnglishToJapanese;
    NSString *suite = [@"local.bawan.UpdateSmoke." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults setBool:YES forKey:@"firstLaunchShown"];
    UpdateTerminationSmokeDelegate *delegate = [[UpdateTerminationSmokeDelegate alloc]
        initWithDefaults:defaults launchMode:bawan::InteractiveLaunch{}];
    delegate.terminationReplies = [NSMutableArray array];
    ScopedEngineCallbackSuppression callbacks(delegate);
    TranslationPanel *panel = [[TranslationPanel alloc] init];
    [delegate connectTranslationPanel:panel];
    [delegate buildMenus];
    [panel showForManualInput];
    AppUpdater *updater = [[AppUpdater alloc] init];
    AttachTestUpdater(delegate, updater);
    NSTextView *output = [panel valueForKey:@"output"];

    @try {
        panel.onTranslate(@"Waiting for model verification", direction);
        Require([delegate busy] && ActiveRequestId(delegate) == 0,
            @"A request without a verified model must remain queued");
        Require(![updater updater:nil shouldPostponeRelaunchForUpdate:nil untilInvokingBlock:^{}],
            @"Waiting for a model without a running translation must not postpone installation");
        Require([delegate applicationShouldTerminate:NSApp] == NSTerminateNow,
            @"An update must be able to close the app while a translation only awaits setup");
        SetAvailableModel(delegate);
        Require(ActiveRequestId(delegate) == 0,
            @"A verified model must not start queued work once installation begins");
        AbortUpdate(updater);
        const auto queued = ActiveRequestId(delegate);
        Require(queued != 0, @"An aborted update must resume queued work after model verification");
        Require([delegate applicationShouldTerminate:NSApp] == NSTerminateNow,
            @"An ordinary Quit must not be held for an active translation");
        NSError *error = nil;
        Require(![updater updater:nil mayPerformUpdateCheck:SPUUpdateCheckUpdates error:&error] &&
            error.localizedDescription.length &&
            ![updater updater:nil mayPerformUpdateCheck:SPUUpdateCheckUpdatesInBackground error:nullptr],
            @"Manual and background update checks must wait for active translation");
        [delegate cancelTranslation];
        Require([updater updater:nil mayPerformUpdateCheck:SPUUpdateCheckUpdates error:nullptr],
            @"An idle application must allow update checks");

        __block NSUInteger installs = 0;
        panel.onTranslate(@"Translation before Sparkle postponement", direction);
        const auto postponed = ActiveRequestId(delegate);
        Require(postponed != 0 &&
            [updater updater:nil shouldPostponeRelaunchForUpdate:nil untilInvokingBlock:^{ ++installs; }],
            @"Sparkle must defer the restart while a translation is running");
        panel.onTranslate(@"Replacement attempted during postponement", direction);
        [delegate handleSelectionText:@"Selection attempted during postponement"];
        Require(ActiveRequestId(delegate) == postponed,
            @"Sparkle postponement must reject requests that could replace the active translation");
        [delegate injectEngineEvent:Progress{postponed, "Partial result", direction}];
        [delegate injectEngineEvent:Finished{queued, Complete{"Stale result", false, direction}}];
        DrainUpdateEvents();
        Require(installs == 0 && !delegate.copiedOutput && [output.string isEqualToString:@"Partial result"],
            @"Neither streaming nor a stale completion may release the delayed update");
        __block NSString *shownAtChoice = nil;
        __block NSUInteger installsAtChoice = 0;
        delegate.chooseRestart = ^NSModalResponse(NSAlert *) {
            shownAtChoice = output.string;
            installsAtChoice = installs;
            return NSAlertFirstButtonReturn;
        };
        [delegate injectEngineEvent:Finished{postponed, Complete{"Full result to copy", false, direction}}];
        Require(installs == 0, @"Sparkle must wait for a choice after the final translation");
        WaitFor(^BOOL { return installs == 1; }, @"The update did not resume after choosing Copy and Restart");
        Require(installsAtChoice == 0 && [shownAtChoice isEqualToString:@"Full result to copy"] &&
            [delegate.copiedOutput isEqualToString:shownAtChoice],
            @"Copy and Restart must copy the displayed complete translation before releasing the update");
        panel.onTranslate(@"Manual translation during install", direction);
        Require(![delegate busy], @"A new translation must be rejected after the install handoff");
        [delegate handleSelectionText:@"Selection translation during install"];
        Require(![delegate busy], @"A new selection must be rejected after the install handoff");
        AbortUpdate(updater);

        panel.onTranslate(@"Translation before a direct install", direction);
        const auto direct = ActiveRequestId(delegate);
        [updater updater:nil willInstallUpdate:nil];
        Require(direct != 0 && [delegate applicationShouldTerminate:NSApp] == NSTerminateLater,
            @"A direct Sparkle install must defer AppKit termination for a running translation");
        [delegate injectEngineEvent:Finished{direct, Complete{"Direct install result", false, direction}}];
        Require(delegate.terminationReplies.count == 0,
            @"AppKit must wait for a choice after the final translation");
        WaitFor(^BOOL { return delegate.terminationReplies.count == 1; },
            @"Copy and Restart did not answer the outstanding AppKit termination");
        Require([delegate.terminationReplies.firstObject boolValue] &&
            [delegate.copiedOutput isEqualToString:@"Direct install result"],
            @"The AppKit termination path must also copy the final result before replying YES");
        AbortUpdate(updater);
        [delegate.terminationReplies removeAllObjects];

        panel.onTranslate(@"Translation finishing before AppKit receives termination", direction);
        const auto beforeTerminate = ActiveRequestId(delegate);
        [updater updater:nil willInstallUpdate:nil];
        [delegate injectEngineEvent:Finished{beforeTerminate, Complete{"Final result before AppKit", false, direction}}];
        Require(beforeTerminate != 0 && [delegate applicationShouldTerminate:NSApp] == NSTerminateLater,
            @"An update must still hold termination if the final result arrived first");
        WaitFor(^BOOL { return delegate.terminationReplies.count == 1; },
            @"Choosing to restart must release termination for the early result");
        Require([delegate.copiedOutput isEqualToString:@"Final result before AppKit"] &&
            [delegate.terminationReplies.firstObject boolValue],
            @"The result must be copied even if it arrived while Sparkle prepared to terminate");
        AbortUpdate(updater);
        [delegate.terminationReplies removeAllObjects];

        panel.onTranslate(@"Translation before an aborted install", direction);
        const auto aborted = ActiveRequestId(delegate);
        [updater updater:nil willInstallUpdate:nil];
        Require(aborted != 0 && [delegate applicationShouldTerminate:NSApp] == NSTerminateLater,
            @"The abort fixture must have outstanding AppKit termination");
        delegate.chooseRestart = ^NSModalResponse(NSAlert *) {
            AbortUpdate(updater);
            return NSAlertFirstButtonReturn;
        };
        [delegate injectEngineEvent:Finished{aborted, Complete{"Result safe after abort", false, direction}}];
        WaitFor(^BOOL { return delegate.terminationReplies.count == 1; },
            @"Aborting an update while choosing whether to copy must answer AppKit");
        Require(![delegate.terminationReplies.firstObject boolValue] &&
            [output.string isEqualToString:@"Result safe after abort"] &&
            [delegate.copiedOutput isEqualToString:@"Final result before AppKit"],
            @"An aborted update must preserve the displayed output and invalidate the restart choice");
        delegate.chooseRestart = nil;
        [delegate.terminationReplies removeAllObjects];

        for (Outcome outcome : {Outcome{Complete{"", false, direction}}, Outcome{Error{"Error"}}, Outcome{Cancelled{}}}) {
            panel.onTranslate(@"Result-free termination", direction);
            const auto request = ActiveRequestId(delegate);
            [updater updater:nil willInstallUpdate:nil];
            Require(request != 0 && [delegate applicationShouldTerminate:NSApp] == NSTerminateLater,
                @"Terminal-outcome fixtures must defer while their requests are active");
            [delegate injectEngineEvent:Finished{request, outcome}];
            WaitFor(^BOOL { return delegate.terminationReplies.count == 1; },
                @"An empty, failed or cancelled translation must release the update");
            Require([delegate.terminationReplies.firstObject boolValue], @"The update must be allowed to complete");
            AbortUpdate(updater);
            [delegate.terminationReplies removeAllObjects];
        }
    } @finally {
        [panel close];
        [delegate applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:NSApp]];
        [defaults removePersistentDomainForName:suite];
    }
}

static int RunUpdateTerminationProbe(void) {
    const auto direction = bawan::Direction::EnglishToJapanese;
    NSString *suite = [@"local.bawan.UpdateTerminationProbe." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults setBool:YES forKey:@"firstLaunchShown"];
    TranslationPanel *panel = [[TranslationPanel alloc] init];
    AppUpdater *updater = [[AppUpdater alloc] init];
    UpdateTerminationProbeDelegate *delegate = [[UpdateTerminationProbeDelegate alloc]
        initWithDefaults:defaults launchMode:bawan::InteractiveLaunch{}];
    ScopedEngineCallbackSuppression callbacks(delegate);
    delegate.expectedOutput = @"A deterministic test result delivered in modal termination mode";
    delegate.probeDefaults = defaults;
    delegate.defaultsSuite = suite;
    delegate.probePasteboard = NSPasteboard.pasteboardWithUniqueName;
    AttachTestUpdater(delegate, updater);
    [delegate connectTranslationPanel:panel];
    [delegate buildMenus];
    [NSApp setDelegate:delegate];
    [panel showForManualInput];
    SetAvailableModel(delegate);
    panel.onTranslate(@"Source text", direction);
    const auto request = ActiveRequestId(delegate);
    if (!request) {
        std::cerr << "FAIL: update termination probe could not start an active request\n";
        return EXIT_FAILURE;
    }
    [updater updater:nil willInstallUpdate:nil];

    NSTimer *delivery = [NSTimer timerWithTimeInterval:0.05 repeats:NO block:^(NSTimer *) {
        PerformInApplicationRunLoop(^{
            [delegate injectEngineEvent:Progress{request, "A deterministic test result", direction}];
            [delegate injectEngineEvent:Finished{request, Complete{delegate.expectedOutput.UTF8String, false, direction}}];
        });
    }];
    [NSRunLoop.mainRunLoop addTimer:delivery forMode:NSModalPanelRunLoopMode];
    NSTimer *watchdog = [NSTimer timerWithTimeInterval:8 repeats:NO block:^(NSTimer *) {
        std::cerr << "FAIL: bounded AppKit termination probe did not deliver its final result\n";
        std::exit(EXIT_FAILURE);
    }];
    [NSRunLoop.mainRunLoop addTimer:watchdog forMode:NSModalPanelRunLoopMode];
    [NSRunLoop.mainRunLoop addTimer:watchdog forMode:NSDefaultRunLoopMode];
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
    [NSApp run];
    [panel close];
    [defaults removePersistentDomainForName:suite];
    return UpdateTerminationProbePassed ? EXIT_SUCCESS : EXIT_FAILURE;
}
#endif

static NSString *ProbeCommand(NSString *directory, NSString *command) {
    NSString *reply = [directory stringByAppendingPathComponent:@"reply"];
    [NSFileManager.defaultManager removeItemAtPath:reply error:nil];
    [command writeToFile:[directory stringByAppendingPathComponent:@"command"]
        atomically:YES encoding:NSUTF8StringEncoding error:nil];
    WaitFor([&] { return [NSFileManager.defaultManager fileExistsAtPath:reply]; },
        @"Probe command must reply before timeout");
    Require(![NSFileManager.defaultManager fileExistsAtPath:[directory stringByAppendingPathComponent:@"command"]],
        @"Commands must be consumed once");
    return [NSString stringWithContentsOfFile:reply encoding:NSUTF8StringEncoding error:nil];
}

static void CheckMemoryProbe(void) {
    Require(std::holds_alternative<bawan::InteractiveLaunch>(bawan::LaunchModeFromEnvironment(@{})),
        @"Missing probe environment must select interactive launch");
    Require(std::holds_alternative<bawan::InteractiveLaunch>(
        bawan::LaunchModeFromEnvironment(@{@"BAWAN_MEMORY_PROBE": @""})),
        @"Empty probe environment must select interactive launch");
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    auto mode = bawan::LaunchModeFromEnvironment(@{@"BAWAN_MEMORY_PROBE": directory});
    Require(std::holds_alternative<bawan::MemoryProbeLaunch>(mode) &&
        [std::get<bawan::MemoryProbeLaunch>(mode).directory isEqualToString:directory],
        @"Nonempty probe environment must preserve the probe directory");
    Require([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:NO
        attributes:nil error:nil], @"Probe fixture directory must be created");
    __block NSUInteger calls = 0;
    MemoryProbe *probe = [[MemoryProbe alloc] initWithDirectory:directory commands:@{
        @"ping": ^NSString *{ ++calls; return @"ok"; },
        @"model": ^NSString *{ return @"waiting"; },
        @"ready": ^NSString *{ return @"ready"; },
        @"failed": ^NSString *{ return @"error"; }
    }];
    [probe start];
    NSString *reply = [directory stringByAppendingPathComponent:@"reply"];
    NSString *engine = [directory stringByAppendingPathComponent:@"engine"];
    @try {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        Require(![NSFileManager.defaultManager fileExistsAtPath:reply], @"No command must produce no reply");
        for (NSString *value in @[@"ping", @"", @"unknown", @"model", @"ready", @"failed"]) {
            NSString *expected = [value isEqualToString:@"ping"] ? @"ok" :
                ([value isEqualToString:@"model"] ? @"waiting" : ([value isEqualToString:@"ready"] ? @"ready" : @"error"));
            Require([ProbeCommand(directory, value) isEqualToString:expected],
                @"Probe commands must acknowledge success, waiting, readiness, and errors");
        }
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        Require(calls == 1, @"Consumed commands must not dispatch again");
        const std::pair<bawan::EngineEvent, NSString *> events[] = {
            {Finished{99, Complete{"", false, bawan::Direction::EnglishToJapanese}}, @"complete"},
            {Lifecycle{Idle{}}, @"idle"},
            {Finished{99, Error{"request failure"}}, @"error"},
            {Lifecycle{Failed{"load failure"}}, @"error"},
            {Lifecycle{LoadCancelled{}}, @"error"},
        };
        for (const auto &[event, expected] : events) {
            [probe recordEngineEvent:event];
            Require([[NSString stringWithContentsOfFile:engine encoding:NSUTF8StringEncoding error:nil]
                isEqualToString:expected], @"Probe must expose completion, actual unload, and engine errors");
        }
        [NSFileManager.defaultManager removeItemAtPath:engine error:nil];
        [probe recordEngineEvent:Lifecycle{Loading{}}];
        [probe recordEngineEvent:Lifecycle{Ready{}}];
        [probe recordEngineEvent:Progress{99, "ongoing", bawan::Direction::EnglishToJapanese}];
        Require(![NSFileManager.defaultManager fileExistsAtPath:engine], @"Nonterminal events must not write engine state");
        __weak MemoryProbe *weakProbe;
        @autoreleasepool {
            MemoryProbe *scheduled = [[MemoryProbe alloc] initWithDirectory:directory commands:@{}];
            weakProbe = scheduled;
            [scheduled start];
        }
        Require(!weakProbe, @"The scheduled timer must not retain its probe");
    } @finally {
        probe = nil;
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    }
}

static void CheckMemoryProbeIntegration(void) {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    Require([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:NO
        attributes:nil error:nil], @"Integration probe directory must be created");
    for (BOOL probing : {YES, NO}) {
        NSString *suite = [@"local.bawan.ProbeIntegration." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        [defaults removePersistentDomainForName:suite];
        bawan::LaunchMode mode = probing ? bawan::LaunchMode{bawan::MemoryProbeLaunch{directory}} :
            bawan::LaunchMode{bawan::InteractiveLaunch{}};
        SetupSmokeDelegate *delegate = [[SetupSmokeDelegate alloc] initWithDefaults:defaults launchMode:mode];
        Require(Flag(delegate, @"needsOnboarding") == !probing,
            @"Onboarding must depend on launch mode before the probe exists");
        @try {
            [delegate applicationDidFinishLaunching:
                [NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp]];
            TranslationPanel *panel = [delegate valueForKey:@"translationPanel"];
            if (probing) {
                Require(!panel.window.visible && ![delegate valueForKey:@"onboardingViewController"] &&
                    [delegate valueForKey:@"memoryProbe"] && !Flag(delegate, @"needsOnboarding") &&
                    !Flag(delegate, @"hasVerifiedModelFile") && delegate.licenseViews == 0,
                    @"Probe launch must skip setup and onboarding");
                Require([ProbeCommand(directory, @"ping") isEqualToString:@"ok"], @"Wired ping must acknowledge success");
                Require([ProbeCommand(directory, @"unknown") isEqualToString:@"error"], @"Wired unknown command must fail");
                Require([ProbeCommand(directory, @"model") isEqualToString:@"waiting"], @"Probe launch must not prepare the model");
                Require([ProbeCommand(directory, @"translation") isEqualToString:@"ok"] &&
                    panel.window.visible && panel.currentPage == BawanPanelPageTranslation,
                    @"Wired translation command must show the real panel");
                Require([ProbeCommand(directory, @"close") isEqualToString:@"ok"] && !panel.window.visible,
                    @"Wired close command must hide the real panel");
                [delegate injectEngineEvent:Lifecycle{Idle{}}];
                Require([[NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:@"engine"]
                    encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"idle"],
                    @"Delegate engine events must reach the probe file");
                Require([ProbeCommand(directory, @"setup") isEqualToString:@"ok"] &&
                    panel.currentPage == BawanPanelPageOnboarding, @"Wired setup must show onboarding explicitly");
            } else {
                Require(panel.window.visible && panel.currentPage == BawanPanelPageOnboarding &&
                    [delegate valueForKey:@"onboardingViewController"] && Flag(delegate, @"needsOnboarding") &&
                    ![delegate valueForKey:@"memoryProbe"], @"Interactive launch must run initial onboarding");
            }
            Require(![defaults boolForKey:@"firstLaunchShown"], @"Probe and interactive startup must not complete onboarding");
        } @finally {
            [[delegate valueForKey:@"translationPanel"] close];
            [delegate applicationWillTerminate:
                [NSNotification notificationWithName:NSApplicationWillTerminateNotification object:NSApp]];
            [defaults removePersistentDomainForName:suite];
        }
    }
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        if (![NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]) {
            std::cerr << "FAIL: AppKit smoke fixture could not use accessory activation policy\n";
            return EXIT_FAILURE;
        }
        [NSApp finishLaunching];
#if BAWAN_ENABLE_UPDATES
        if (argc == 2 && std::string(argv[1]) == "--update-termination-probe") {
            return RunUpdateTerminationProbe();
        }
        if (argc == 2 && std::string(argv[1]) == "--update-termination-behavior") {
            try {
                CheckUpdateTerminationBehavior();
                CheckUpdateWithQueuedSelectionAndPractice();
                std::cout << "PASS: update termination behavior assertions\n";
                return EXIT_SUCCESS;
            } catch (const std::exception &error) {
                std::cerr << "FAIL: " << error.what() << '\n';
                return EXIT_FAILURE;
            }
        }
#endif
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
        SmokeAppDelegate *delegate = [[SmokeAppDelegate alloc] initWithDefaults:defaults launchMode:bawan::InteractiveLaunch{}];
        [delegate connectModelStore:[[SetupSmokeStore alloc] init]];
        TranslationPanel *panel = [[TranslationPanel alloc] init];
        [delegate connectTranslationPanel:panel];
        [delegate buildMenus];
        [delegate updateStatus];
        int result = EXIT_SUCCESS;
        @try {
            try {
                CheckEngineHostReset();
                CheckPendingSelection(delegate, panel);
                CheckMemoryProbe();
                CheckMemoryProbeIntegration();
                CheckEditedRequests(delegate, panel);
                CheckColdRequestAndRetry(delegate);
                CheckWarmUpFailure(delegate);
                CheckModelStatusPresentation(delegate, panel);
                CheckModelRevalidationOnRetry(delegate);
                CheckFirstRunSelection();
                CheckSelectionTrial();
                CheckFirstRunIntegration();
                CheckModelLicenseSheet();
                CheckPageRelease();
                CheckDownloadActions();
                std::cout << "PASS: pending selection cancellation, source edits, stale output isolation, cold load errors, warmup errors, retry isolation, verification stamps, model revalidation, first-run selection translation, first-run navigation, the license sheet and contextual download actions\n";
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
