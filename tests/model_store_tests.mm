#import "ModelStore.h"

#include <cstdlib>
#include <functional>
#include <iostream>
#include <stdexcept>

@interface ModelStore (DownloadFixture)
- (instancetype)initWithFileManager:(NSFileManager *)files expectedSize:(int64_t)expectedSize
                            SHA256:(NSString *)expectedSHA256 downloadURL:(NSURL *)downloadURL
              sessionConfiguration:(NSURLSessionConfiguration *)configuration;
@end

@interface DownloadFixtureFiles : NSFileManager
@property(nonatomic, strong) NSURL *supportDirectory;
@end
@implementation DownloadFixtureFiles
- (NSURL *)URLForDirectory:(NSSearchPathDirectory)directory inDomain:(NSSearchPathDomainMask)domain
    appropriateForURL:(NSURL *)url create:(BOOL)create error:(NSError **)error {
    if (directory == NSApplicationSupportDirectory && domain == NSUserDomainMask) return _supportDirectory;
    return [super URLForDirectory:directory inDomain:domain appropriateForURL:url create:create error:error];
}
@end

// A held response emits its prefix but never EOF. The test pauses or cancels
// only after ModelStore reports those bytes, so the saved offset is deterministic.
@interface DownloadFixtureProtocol : NSURLProtocol
+ (void)setResponses:(NSArray<NSDictionary *> *)responses;
+ (NSArray<NSURLRequest *> *)requests;
+ (void)failActiveRequest;
@end

static NSMutableArray<NSDictionary *> *scriptedResponses;
static NSMutableArray<NSURLRequest *> *observedRequests;
static __weak DownloadFixtureProtocol *activeProtocol;

@implementation DownloadFixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return [request.URL.host isEqualToString:@"model.test"];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
+ (void)setResponses:(NSArray<NSDictionary *> *)responses {
    @synchronized(self) {
        scriptedResponses = [responses mutableCopy];
        observedRequests = [NSMutableArray array];
        activeProtocol = nil;
    }
}
+ (NSArray<NSURLRequest *> *)requests {
    @synchronized(self) { return [observedRequests copy]; }
}
+ (void)failActiveRequest {
    DownloadFixtureProtocol *protocol = nil;
    @synchronized(self) { protocol = activeProtocol; }
    [protocol.client URLProtocol:protocol didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
        code:NSURLErrorNetworkConnectionLost userInfo:nil]];
}
- (void)startLoading {
    NSDictionary *step = nil;
    @synchronized(DownloadFixtureProtocol.class) {
        activeProtocol = self;
        [observedRequests addObject:[self.request copy]];
        if (scriptedResponses.count) {
            step = scriptedResponses.firstObject;
            [scriptedResponses removeObjectAtIndex:0];
        }
    }
    if (!step) {
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
            code:NSURLErrorResourceUnavailable userInfo:nil]];
        return;
    }
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
        statusCode:[step[@"status"] integerValue] HTTPVersion:@"HTTP/1.1" headerFields:step[@"headers"]];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    NSData *bytes = step[@"body"];
    if (bytes.length) [self.client URLProtocol:self didLoadData:bytes];
    if (![step[@"hold"] boolValue]) {
        [self.client URLProtocolDidFinishLoading:self];
    }
}
- (void)stopLoading {
    @synchronized(DownloadFixtureProtocol.class) {
        if (activeProtocol == self) activeProtocol = nil;
    }
}
@end

static void Require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}

static void WaitFor(const std::function<bool()> &condition, const char *message) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        @autoreleasepool {
            [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
    }
    Require(condition(), message);
}

static NSString *const FixtureSHA256 = @"32e5e24230b47f8db398a288c8a7ca84723ba83d0099fceeaecdec1976d25c30";
static NSString *const FixtureFilename = @"plamo-3-translate-0.8b-Q4_K_M.gguf";

struct Fixture {
    DownloadFixtureFiles *files;
    ModelStore *store;
    NSURL *source;
    NSURL *model;
    NSURL *partial;
    NSURL *sidecar;
    NSData *body;
    NSUInteger ready = 0;
    NSUInteger errors = 0;
    NSString *error = nil;
    NSURL *readyURL = nil;
    double progress = 0;
    bool callbacksOnMain = true;
    const bool ownsSupportDirectory;

    explicit Fixture(NSURL *sharedSupport = nil) : ownsSupportDirectory(sharedSupport == nil) {
        files = [[DownloadFixtureFiles alloc] init];
        files.supportDirectory = sharedSupport ?: [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:[@"bawan-model-test-" stringByAppendingString:NSUUID.UUID.UUIDString]
                           isDirectory:YES];
        source = [NSURL URLWithString:@"https://model.test/fixture.gguf"];
        NSURL *directory = [files.supportDirectory URLByAppendingPathComponent:@"local.bawan.Bawan" isDirectory:YES];
        model = [directory URLByAppendingPathComponent:FixtureFilename];
        partial = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.partial", FixtureFilename]];
        sidecar = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.partial.plist", FixtureFilename]];
        body = [@"valid model fixture" dataUsingEncoding:NSUTF8StringEncoding];
        recreateStore();
    }
    ~Fixture() {
        [store cancel];
        if (ownsSupportDirectory) [files removeItemAtURL:files.supportDirectory error:nil];
    }
    void recreateStore() {
        [store cancel];
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.protocolClasses = @[DownloadFixtureProtocol.class];
        store = [[ModelStore alloc] initWithFileManager:files expectedSize:body.length SHA256:FixtureSHA256
            downloadURL:source sessionConfiguration:configuration];
        Fixture *owner = this;
        store.onReady = ^(NSURL *url) {
            owner->callbacksOnMain &= NSThread.isMainThread;
            ++owner->ready;
            owner->readyURL = url;
        };
        store.onError = ^(NSString *message) {
            owner->callbacksOnMain &= NSThread.isMainThread;
            ++owner->errors;
            owner->error = message;
        };
        store.onProgress = ^(double fraction, NSString *) {
            owner->callbacksOnMain &= NSThread.isMainThread;
            owner->progress = fraction;
        };
        store.onStateChange = ^(ModelStoreState) { owner->callbacksOnMain &= NSThread.isMainThread; };
    }
    NSData *prefix() const { return [body subdataWithRange:NSMakeRange(0, 7)]; }
    NSData *suffix() const { return [body subdataWithRange:NSMakeRange(7, body.length - 7)]; }
    NSDictionary *response(NSInteger status, NSData *bytes, NSDictionary *extraHeaders = nil,
                           bool hold = false) const {
        NSMutableDictionary *headers = [@{@"Content-Type": @"application/octet-stream", @"ETag": @"\"v1\"",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)(hold ? body.length : bytes.length)]}
            mutableCopy];
        [headers addEntriesFromDictionary:extraHeaders ?: @{}];
        return @{@"status": @(status), @"headers": headers, @"body": bytes ?: [NSData data],
                 @"hold": @(hold)};
    }
    NSDictionary *continuation(NSData *bytes = nil, NSString *etag = @"\"v1\"") const {
        return response(206, bytes ?: suffix(), @{@"Content-Range": @"bytes 7-18/19", @"ETag": etag});
    }
    void seed(NSData *bytes, NSDictionary *changes = nil) const {
        Require([files createDirectoryAtURL:model.URLByDeletingLastPathComponent
                withIntermediateDirectories:YES attributes:nil error:nil], "Create partial fixture directory");
        Require([bytes writeToURL:partial atomically:YES], "Write partial fixture bytes");
        NSMutableDictionary *metadata = [@{@"url": source.absoluteString, @"size": @(body.length),
            @"sha256": FixtureSHA256, @"etag": @"\"v1\""} mutableCopy];
        [metadata addEntriesFromDictionary:changes ?: @{}];
        Require([metadata writeToURL:sidecar atomically:YES], "Write partial fixture metadata");
    }
    void awaitReady() const {
        WaitFor([&] { return ready || errors; }, "Model download did not reach Ready or Error");
        Require(ready == 1 && errors == 0, "Valid downloaded bytes must pass SHA256 and report Ready");
        Require(store.state == ModelStoreReady && [readyURL isEqual:model], "Ready must expose the final model URL");
        Require([[NSData dataWithContentsOfURL:model] isEqual:body], "Final model bytes must equal the complete fixture");
        Require(![files fileExistsAtPath:partial.path] && ![files fileExistsAtPath:sidecar.path],
                "Verified download must remove partial and metadata");
        Require(callbacksOnMain, "All ModelStore callbacks must arrive on the main thread");
    }
    void awaitPrefix() const {
        WaitFor([&] { return progress > 0 || errors; }, "Held response prefix was not persisted");
        Require(!errors && store.state == ModelStoreDownloading, "Held response must still be downloading");
    }
};

static void RequireResumeRequest(NSUInteger index = 1) {
    NSArray<NSURLRequest *> *requests = DownloadFixtureProtocol.requests;
    Require(requests.count > index, "Resume must send another HTTP request");
    Require([[requests[index] valueForHTTPHeaderField:@"Range"] isEqualToString:@"bytes=7-"],
            "Resume must request only the bytes after the persisted prefix");
    Require([[requests[index] valueForHTTPHeaderField:@"If-Range"] isEqualToString:@"\"v1\""],
            "Resume must bind the partial file to its strong ETag");
}

static void CheckPauseAndResume() {
    Fixture f;
    [DownloadFixtureProtocol setResponses:@[f.response(200, f.prefix(), nil, true), f.continuation()]];
    [f.store prepare];
    f.awaitPrefix();
    [f.store pause];
    Require(f.store.state == ModelStorePaused && f.store.canResume, "Pause must expose a resumable paused state");
    Require([[NSData dataWithContentsOfURL:f.partial] isEqual:f.prefix()], "Pause must preserve every reported byte");
    const double paused = f.progress;
    Require(paused > 0 && paused < 1, "Pause must retain the acquired fraction");
    [f.store resume];
    f.awaitReady();
    RequireResumeRequest();
}

static void CheckConcurrentDownloadsPreserveProgress() {
    Fixture first;
    Fixture second(first.files.supportDirectory);
    NSData *restartPrefix = [first.body subdataWithRange:NSMakeRange(0, 2)];
    // A second downloader would accept a 200 restart and truncate the live prefix.
    [DownloadFixtureProtocol setResponses:@[first.response(200, first.prefix(), nil, true),
                                            second.response(200, restartPrefix, nil, true)]];
    [first.store prepare];
    first.awaitPrefix();
    [second.store prepare];
    WaitFor([&] { return second.errors || second.progress == 2.0 / first.body.length; },
            "Concurrent preparation did not report failure or restart the transfer");
    Require([[NSData dataWithContentsOfURL:first.partial] isEqual:first.prefix()],
            "A second instance must not truncate the active model download");
    Require(second.errors == 1 && second.store.state == ModelStoreFailed &&
            DownloadFixtureProtocol.requests.count == 1,
            "A second instance must report that the model download is busy without contacting the server");

    [first.store pause];
    [DownloadFixtureProtocol setResponses:@[second.continuation()]];
    second.errors = 0;
    [second.store prepare];
    second.awaitReady();
    RequireResumeRequest(0);
}

static void CheckProcessRestart() {
    Fixture f;
    [DownloadFixtureProtocol setResponses:@[f.response(200, f.prefix(), nil, true), f.continuation()]];
    [f.store prepare];
    f.awaitPrefix();
    [f.store cancel];
    f.recreateStore();
    [f.store prepare];
    f.awaitReady();
    RequireResumeRequest();
}

static void CheckNetworkFailure() {
    Fixture f;
    [DownloadFixtureProtocol setResponses:@[f.response(200, f.prefix(), nil, true), f.continuation()]];
    [f.store prepare];
    f.awaitPrefix();
    [DownloadFixtureProtocol failActiveRequest];
    WaitFor([&] { return f.errors != 0; }, "Connection loss must report an error");
    Require(f.store.state == ModelStoreFailed && f.store.canResume, "Connection loss must retain a resumable prefix");
    Require(!f.ready && [[NSData dataWithContentsOfURL:f.partial] isEqual:f.prefix()],
            "Connection loss must never expose an unverified model");
    f.errors = 0;
    [f.store resume];
    f.awaitReady();
    RequireResumeRequest();
}

static void CheckRangeIgnored() {
    Fixture f;
    f.seed(f.prefix());
    [DownloadFixtureProtocol setResponses:@[f.response(200, f.body, @{@"ETag": @"\"v2\""})]];
    [f.store prepare];
    f.awaitReady();
    RequireResumeRequest(0);
    Require(DownloadFixtureProtocol.requests.count == 1, "A full 200 response must replace the prefix without another download");
}

static void CheckFreshPartialResponse() {
    Fixture f;
    [DownloadFixtureProtocol setResponses:@[f.response(206, f.body,
        @{@"Content-Range": @"bytes 0-18/19"})]];
    [f.store prepare];
    f.awaitReady();
    Require(DownloadFixtureProtocol.requests.count == 1,
            "A valid complete 206 response must create a fresh partial and verify it");
}

static void CheckInvalidPartials() {
    NSArray<NSDictionary *> *changes = @[
        @{@"url": @"https://model.test/other.gguf"}, @{@"size": @20}, @{@"sha256": @"wrong"},
        @{@"etag": @"W/\"v1\""}, @{@"etag": @""}
    ];
    for (NSDictionary *change in changes) {
        Fixture f;
        f.seed(f.prefix(), change);
        [DownloadFixtureProtocol setResponses:@[f.response(200, f.body)]];
        [f.store prepare];
        f.awaitReady();
        Require(DownloadFixtureProtocol.requests.count == 1 &&
            [DownloadFixtureProtocol.requests[0] valueForHTTPHeaderField:@"Range"] == nil,
            "Partial metadata for another resource or without a strong validator must restart from zero");
    }
    for (NSNumber *corruptMetadata in @[@NO, @YES]) {
        Fixture f;
        f.seed(f.prefix());
        if (corruptMetadata.boolValue) {
            Require([[@"invalid plist" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:f.sidecar atomically:YES],
                    "Write malformed partial metadata");
        } else {
            Require([f.files removeItemAtURL:f.sidecar error:nil], "Remove partial metadata");
        }
        [DownloadFixtureProtocol setResponses:@[f.response(200, f.body)]];
        [f.store prepare];
        f.awaitReady();
        Require([DownloadFixtureProtocol.requests[0] valueForHTTPHeaderField:@"Range"] == nil,
                "Missing or malformed metadata must never authorize appending to old bytes");
    }
    for (NSData *bytes in @[[NSData data], [@"longer than expected model" dataUsingEncoding:NSUTF8StringEncoding]]) {
        Fixture f;
        f.seed(bytes);
        [DownloadFixtureProtocol setResponses:@[f.response(200, f.body)]];
        [f.store prepare];
        f.awaitReady();
        Require([DownloadFixtureProtocol.requests[0] valueForHTTPHeaderField:@"Range"] == nil,
                "An empty or oversized partial must restart from zero");
    }
}

static void CheckInterruptedWithoutValidator() {
    for (NSString *etag in @[@"", @"W/\"v1\""]) {
        Fixture f;
        [DownloadFixtureProtocol setResponses:@[
            f.response(200, f.prefix(), @{@"ETag": etag}, true), f.response(200, f.body)]];
        [f.store prepare];
        f.awaitPrefix();
        [f.store pause];
        Require(f.store.state == ModelStorePaused, "A download without a strong ETag must still pause");
        [f.store resume];
        f.awaitReady();
        Require(DownloadFixtureProtocol.requests.count == 2 &&
            [DownloadFixtureProtocol.requests[1] valueForHTTPHeaderField:@"Range"] == nil,
            "An interrupted download without a strong validator must safely restart from zero");
    }
}

static void CheckRejectedRangeResponses() {
    for (NSDictionary *headers in @[
        @{@"Content-Range": @"bytes 6-18/19"}, @{@"Content-Range": @"bytes 7-18/20"},
        @{@"Content-Range": @"garbage"}, @{@"Content-Range": @"bytes 7-18/19", @"ETag": @"\"v2\""},
        @{@"Content-Range": @"bytes 7-18/19", @"ETag": @""},
        @{@"Content-Range": @"bytes 7-18/19", @"ETag": @"W/\"v1\""}
    ]) {
        Fixture f;
        f.seed(f.prefix());
        [DownloadFixtureProtocol setResponses:@[f.response(206, f.suffix(), headers), f.response(200, f.body)]];
        [f.store prepare];
        WaitFor([&] { return f.ready || f.errors; }, "Invalid range response did not terminate");
        Require(!f.ready || [[NSData dataWithContentsOfURL:f.model] isEqual:f.body],
                "Mismatched range boundaries/ETag must never publish mixed bytes");
        if (f.errors) {
            Require(f.store.state == ModelStoreFailed, "Rejected range must expose an error state");
            f.errors = 0;
            [f.store prepare];
        }
        f.awaitReady();
        RequireResumeRequest(0);
        Require(DownloadFixtureProtocol.requests.count == 2 &&
            [DownloadFixtureProtocol.requests[1] valueForHTTPHeaderField:@"Range"] == nil,
                "Retry after rejected range metadata must discard the untrusted prefix");
    }
}

static void CheckRangeNotSatisfiable() {
    Fixture f;
    f.seed(f.prefix());
    [DownloadFixtureProtocol setResponses:@[f.response(416, [NSData data], @{@"Content-Range": @"bytes */19"}),
                                            f.response(200, f.body)]];
    [f.store prepare];
    f.awaitReady();
    RequireResumeRequest(0);
    Require(DownloadFixtureProtocol.requests.count == 2 &&
        [DownloadFixtureProtocol.requests[1] valueForHTTPHeaderField:@"Range"] == nil,
        "HTTP 416 must discard the rejected partial and retry without Range");
}

static void CheckRepeatedRangeFailure() {
    Fixture f;
    f.seed(f.prefix());
    [DownloadFixtureProtocol setResponses:@[f.response(416, [NSData data]),
                                            f.response(416, [NSData data])]];
    [f.store prepare];
    WaitFor([&] { return f.ready || f.errors; }, "Repeated HTTP 416 did not terminate");
    Require(!f.ready && f.errors == 1 && !f.store.canResume &&
            DownloadFixtureProtocol.requests.count == 2,
            "HTTP 416 recovery must stop after one fresh retry and discard its prefix");
}

static void CheckCompletePartial() {
    Fixture f;
    f.seed(f.body);
    [DownloadFixtureProtocol setResponses:@[]];
    [f.store prepare];
    f.awaitReady();
    Require(DownloadFixtureProtocol.requests.count == 0,
            "A complete saved partial must undergo SHA256 without re-downloading any bytes");
}

static void CheckResumedHashFailure() {
    Fixture f;
    f.seed(f.prefix());
    NSData *wrongSuffix = [@"xxxx fixture" dataUsingEncoding:NSUTF8StringEncoding];
    Require(wrongSuffix.length == f.suffix().length, "Hash fixture must preserve the expected file length");
    [DownloadFixtureProtocol setResponses:@[f.continuation(wrongSuffix), f.response(200, f.body)]];
    [f.store prepare];
    WaitFor([&] { return f.ready || f.errors; }, "Resumed hash verification did not terminate");
    Require(f.errors == 1 && f.ready == 0 && f.store.state == ModelStoreFailed && !f.store.canResume,
            "A resumed hash mismatch must report failure and clear resume availability");
    Require([f.error containsString:@"SHA256"] &&
        ([f.error localizedCaseInsensitiveContainsString:@"try again"] ||
         [f.error localizedCaseInsensitiveContainsString:@"download again"]),
        "Hash mismatch must explain verification failure and tell the user to retry");
    Require(![f.files fileExistsAtPath:f.model.path] && ![f.files fileExistsAtPath:f.partial.path] &&
            ![f.files fileExistsAtPath:f.sidecar.path], "Hash mismatch must discard model bytes and resume metadata");
    RequireResumeRequest(0);
    f.errors = 0;
    [f.store prepare];
    f.awaitReady();
    Require(DownloadFixtureProtocol.requests.count == 2 &&
        [DownloadFixtureProtocol.requests[1] valueForHTTPHeaderField:@"Range"] == nil,
        "Retry after failed SHA256 must start a new full download");
}

int main() {
    @autoreleasepool {
        try {
            CheckPauseAndResume();
            CheckConcurrentDownloadsPreserveProgress();
            CheckProcessRestart();
            CheckNetworkFailure();
            CheckRangeIgnored();
            CheckFreshPartialResponse();
            CheckInvalidPartials();
            CheckInterruptedWithoutValidator();
            CheckRejectedRangeResponses();
            CheckRangeNotSatisfiable();
            CheckRepeatedRangeFailure();
            CheckCompletePartial();
            CheckResumedHashFailure();
            std::cout << "PASS: ModelStore pause, restart, HTTP Range and SHA256 verification\n";
        } catch (const std::exception &error) {
            std::cerr << "FAIL: " << error.what() << '\n';
            return EXIT_FAILURE;
        }
    }
    return EXIT_SUCCESS;
}
