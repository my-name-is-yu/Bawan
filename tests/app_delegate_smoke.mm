#import "AppDelegate.h"
#import "TranslationPanel.h"

#include <cstdlib>
#include <iostream>
#include <stdexcept>

// Exercise the real delegate without applicationDidFinishLaunching: no model
// download, global event tap or permission request belongs in this test.
@interface AppDelegate (SmokeTest)
- (void)buildMenus;
- (void)updateStatus;
- (void)translateText:(NSString *)text direction:(lore::Direction)direction;
- (void)warmUpEngine;
- (void)cancelTranslation;
- (void)retryModel:(id)sender;
- (void)handleEngineEvent:(const lore::EngineEvent &)event;
@end

static void Require(BOOL condition, NSString *message) {
    if (!condition) throw std::runtime_error(message.UTF8String);
}

static BOOL Flag(AppDelegate *delegate, NSString *key) {
    return [[delegate valueForKey:key] boolValue];
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
    [delegate setValue:[NSURL fileURLWithPath:@"/__lore_tests__/missing-model.gguf"] forKey:@"modelURL"];
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
    [delegate translateText:@"First selection" direction:lore::Direction::Automatic];
    [delegate translateText:@"Latest selection" direction:lore::Direction::EnglishToJapanese];
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

static void CheckColdRequestAndRetry(AppDelegate *delegate) {
    SetAvailableModel(delegate);
    [delegate translateText:@"Hello" direction:lore::Direction::EnglishToJapanese];
    Require(Flag(delegate, @"busy"), @"A cold translation must enter the cancellable busy state");
    WaitFor([&] { return Flag(delegate, @"modelFailed") && !Flag(delegate, @"busy"); },
        @"Cold model loading did not report its failure to the application");
    RequireModelFailure(delegate);

    // Start another load, then replace its engine before draining the main
    // queue. Retry must invalidate any callbacks retained by that old engine.
    [delegate translateText:@"Try again" direction:lore::Direction::EnglishToJapanese];
    uint64_t oldGeneration = [[delegate valueForKey:@"engineGeneration"] unsignedLongLongValue];
    uint64_t oldRequest = [[delegate valueForKey:@"activeRequestId"] unsignedLongLongValue];
    [delegate retryModel:nil];
    Require([[delegate valueForKey:@"engineGeneration"] unsignedLongLongValue] > oldGeneration,
        @"Retry must invalidate the previous engine's callback generation");
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    lore::EngineEvent staleError{lore::EngineEvent::Kind::Error, oldRequest, "Old request failed"};
    [delegate handleEngineEvent:staleError];
    NSMenuItem *retry = [delegate valueForKey:@"retryItem"];
    Require(!Flag(delegate, @"busy") && !Flag(delegate, @"modelFailed") &&
        !Flag(delegate, @"modelAvailable") && [delegate valueForKey:@"modelURL"] == nil &&
        [[delegate valueForKey:@"modelStatus"] isEqualToString:@"Checking the model…"] && retry.hidden,
        @"Old engine events must not overwrite model setup after Retry");
    // _modelStore was never created, so Retry cannot start network or file work.
}

static void CheckWarmUpFailure(AppDelegate *delegate) {
    SetAvailableModel(delegate);
    [delegate warmUpEngine];
    Require(!Flag(delegate, @"busy"), @"Manual prewarming must not create a translation request");
    WaitFor([&] { return Flag(delegate, @"modelFailed"); },
        @"Model prewarming did not report its failure to the application");
    RequireModelFailure(delegate);
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
        panel.onClose = ^{ [weakDelegate cancelTranslation]; };
        [delegate buildMenus];
        [delegate updateStatus];
        int result = EXIT_SUCCESS;
        @try {
            try {
                CheckPendingSelection(delegate, panel);
                CheckColdRequestAndRetry(delegate);
                CheckWarmUpFailure(delegate);
                std::cout << "PASS: pending selection cancellation, cold load errors, warmup errors and retry isolation\n";
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
