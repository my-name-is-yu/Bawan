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
        panel.onClose = ^{ [weakDelegate cancelTranslation]; };
        [delegate buildMenus];
        [delegate updateStatus];
        int result = EXIT_SUCCESS;
        @try {
            try {
                CheckPendingSelection(delegate, panel);
                CheckColdRequestAndRetry(delegate);
                CheckWarmUpFailure(delegate);
                CheckModelRevalidationOnRetry(delegate);
                std::cout << "PASS: pending selection cancellation, cold load errors, warmup errors, retry isolation and model revalidation\n";
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
