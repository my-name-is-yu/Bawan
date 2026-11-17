#import "ModelStore.h"

#include <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <dispatch/dispatch.h>

// Immutable upstream metadata, verified against the official Hugging Face API:
// https://huggingface.co/api/models/pfnet/plamo-3-translate-0.8b-GGUF/tree/1cf96ae02133958a20074bfdfab76517bb737d00
// Model terms: https://huggingface.co/pfnet/plamo-3-translate-0.8b-GGUF
static NSString *const ModelFilename = @"plamo-3-translate-0.8b-Q4_K_M.gguf";
static NSString *const ModelDownloadURL =
    @"https://huggingface.co/pfnet/plamo-3-translate-0.8b-GGUF/resolve/"
     "1cf96ae02133958a20074bfdfab76517bb737d00/plamo-3-translate-0.8b-Q4_K_M.gguf";
static const off_t ModelSize = 573126848;
static const char ModelSHA256[] =
    "70891ec70dc7ab4205745a38307867c2881b99239f20327927633abfe4bc9ec6";

enum class Verification { Valid, Invalid, Failed, Cancelled };

static const char VerifiedAttribute[] = "local.bawan.verified-sha256";

static std::string VerificationStamp(const struct stat &info, const char *expectedSHA256) {
    char stamp[160];
    std::snprintf(stamp, sizeof(stamp), "1 %s %lld %llu %ld.%09ld", expectedSHA256,
        static_cast<long long>(info.st_size), static_cast<unsigned long long>(info.st_ino),
        static_cast<long>(info.st_mtimespec.tv_sec), static_cast<long>(info.st_mtimespec.tv_nsec));
    return stamp;
}

static bool HasVerificationStamp(int descriptor, const std::string &stamp) {
    char saved[160];
    const ssize_t length = fgetxattr(descriptor, VerifiedAttribute, saved, sizeof(saved), 0, 0);
    return length == static_cast<ssize_t>(stamp.size()) && std::memcmp(saved, stamp.data(), stamp.size()) == 0;
}

static Verification VerifyModel(NSURL *url, const std::atomic<uint64_t>& generation,
                                uint64_t expectedGeneration, int64_t expectedSize,
                                const char *expectedSHA256, bool trustStamp, NSString **reason) {
    std::unique_ptr<FILE, decltype(&std::fclose)> file(
        std::fopen(url.fileSystemRepresentation, "rb"), &std::fclose);
    if (!file) {
        *reason = @"Unable to open the model file. Check the folder permissions.";
        return Verification::Failed;
    }
    struct stat info {};
    if (fstat(fileno(file.get()), &info) != 0) {
        *reason = @"Unable to check the model file size.";
        return Verification::Failed;
    }
    if (!S_ISREG(info.st_mode) || info.st_size != expectedSize) {
        *reason = @"The model file size is incorrect.";
        return Verification::Invalid;
    }
    const std::string stamp = VerificationStamp(info, expectedSHA256);
    if (trustStamp && HasVerificationStamp(fileno(file.get()), stamp)) {
        return generation.load() == expectedGeneration ? Verification::Valid : Verification::Cancelled;
    }

    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    unsigned char buffer[64 * 1024];
    size_t total = 0;
    for (;;) {
        if (generation.load() != expectedGeneration) return Verification::Cancelled;
        const size_t count = std::fread(buffer, 1, sizeof(buffer), file.get());
        if (count) {
            CC_SHA256_Update(&hash, buffer, static_cast<CC_LONG>(count));
            total += count;
        }
        if (count < sizeof(buffer)) {
            if (std::ferror(file.get())) {
                *reason = @"Unable to read the model file.";
                return Verification::Failed;
            }
            break;
        }
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &hash);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    constexpr char digits[] = "0123456789abcdef";
    for (size_t i = 0; i < sizeof(digest); ++i) {
        hex[i * 2] = digits[digest[i] >> 4];
        hex[i * 2 + 1] = digits[digest[i] & 0x0f];
    }
    hex[sizeof(hex) - 1] = '\0';
    if (total != static_cast<size_t>(expectedSize) || std::strcmp(hex, expectedSHA256) != 0) {
        *reason = @"The model file failed SHA256 verification.";
        fremovexattr(fileno(file.get()), VerifiedAttribute, 0);
        return Verification::Invalid;
    }
    struct stat after {};
    if (fstat(fileno(file.get()), &after) == 0 && VerificationStamp(after, expectedSHA256) == stamp) {
        fsetxattr(fileno(file.get()), VerifiedAttribute, stamp.data(), stamp.size(), 0, 0);
    }
    return generation.load() == expectedGeneration ? Verification::Valid : Verification::Cancelled;
}

@interface ModelStore () <NSURLSessionDownloadDelegate> {
    std::atomic<uint64_t> _generation;
    NSURLSession *_session;
    NSURLSessionDownloadTask *_task;
    NSURL *_modelURL;
    NSFileManager *_files;
    int64_t _expectedSize;
    NSString *_expectedSHA256;
    dispatch_queue_t _verificationQueue;
    double _lastReportedFraction;
}
- (instancetype)initWithFileManager:(NSFileManager *)files expectedSize:(int64_t)expectedSize
                            SHA256:(NSString *)expectedSHA256;
@end

@implementation ModelStore

- (instancetype)init {
    return [self initWithFileManager:NSFileManager.defaultManager expectedSize:ModelSize
                             SHA256:@(ModelSHA256)];
}

- (instancetype)initWithFileManager:(NSFileManager *)files expectedSize:(int64_t)expectedSize
                            SHA256:(NSString *)expectedSHA256 {
    self = [super init];
    if (self) {
        _files = files;
        _expectedSize = expectedSize;
        _expectedSHA256 = [expectedSHA256 copy];
        _generation.store(0);
        _verificationQueue = dispatch_queue_create("local.bawan.model-verification",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    }
    return self;
}

- (void)cancel {
    NSAssert(NSThread.isMainThread, @"ModelStore must be used on the main thread");
    ++_generation;
    [_task cancel];
    [_session invalidateAndCancel];
    _task = nil;
    _session = nil;
}

- (void)prepare {
    [self prepareTrustingVerifiedModel:YES];
}

- (void)revalidate {
    [self prepareTrustingVerifiedModel:NO];
}

- (void)prepareTrustingVerifiedModel:(BOOL)trustStamp {
    NSAssert(NSThread.isMainThread, @"ModelStore must be used on the main thread");
    [self cancel];
    const uint64_t generation = _generation.load();
    _lastReportedFraction = -1;
    NSFileManager *files = _files;
    NSError *error = nil;
    NSURL *support = [files URLForDirectory:NSApplicationSupportDirectory
                                 inDomain:NSUserDomainMask
                        appropriateForURL:nil create:YES error:&error];
    NSURL *directory = [support URLByAppendingPathComponent:@"local.bawan.Bawan" isDirectory:YES];
    if (!support || ![files createDirectoryAtURL:directory withIntermediateDirectories:YES
                                     attributes:nil error:&error]) {
        [self reportError:@"Unable to create the model folder." generation:generation];
        return;
    }
    _modelURL = [directory URLByAppendingPathComponent:ModelFilename];
    for (NSURL *entry in [files contentsOfDirectoryAtURL:directory
                            includingPropertiesForKeys:nil options:0 error:nil]) {
        if ([entry.lastPathComponent hasPrefix:@"."] &&
            [entry.lastPathComponent hasSuffix:@".partial"]) {
            [files removeItemAtURL:entry error:nil];
        }
    }
    if ([files fileExistsAtPath:_modelURL.path]) {
        [self reportProgress:0 message:@"Checking the saved model…" generation:generation];
        [self verifyURL:_modelURL downloaded:NO trustStamp:trustStamp generation:generation];
        return;
    }
    [self reportProgress:0 message:@"Downloading the model…" generation:generation];
    if (_generation.load() != generation) return;
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.URLCache = nil;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest = 60;
    configuration.timeoutIntervalForResource = 60 * 60;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self
                                      delegateQueue:NSOperationQueue.mainQueue];
    _task = [_session downloadTaskWithURL:[NSURL URLWithString:ModelDownloadURL]];
    [_task resume];
}

- (void)reportProgress:(double)fraction message:(NSString *)message generation:(uint64_t)generation {
    if (_generation.load() == generation && self.onProgress) self.onProgress(fraction, message);
}

- (void)reportError:(NSString *)message generation:(uint64_t)generation {
    if (_generation.load() == generation && self.onError) self.onError(message);
}

- (void)verifyURL:(NSURL *)url downloaded:(BOOL)downloaded trustStamp:(BOOL)trustStamp
        generation:(uint64_t)generation {
    NSURL *destination = _modelURL;
    dispatch_async(_verificationQueue, ^{
        @autoreleasepool {
            NSString *reason = nil;
            const Verification result = VerifyModel(url, self->_generation, generation,
                self->_expectedSize, self->_expectedSHA256.UTF8String, trustStamp, &reason);
            dispatch_async(dispatch_get_main_queue(), ^{
                NSFileManager *files = self->_files;
                if (self->_generation.load() != generation || result == Verification::Cancelled) {
                    if (downloaded) [files removeItemAtURL:url error:nil];
                    return;
                }
                if (result != Verification::Valid) {
                    NSString *failureReason = reason ?: @"Model verification failed.";
                    if (downloaded || result == Verification::Invalid) {
                        NSError *removeError = nil;
                        if (![files removeItemAtURL:url error:&removeError] &&
                            [files fileExistsAtPath:url.path]) {
                            failureReason = @"Unable to remove the invalid model file. Check the folder permissions.";
                        }
                    }
                    [self reportError:[failureReason stringByAppendingString:@" Please try again."]
                           generation:generation];
                    return;
                }
                if (downloaded) {
                    NSError *moveError = nil;
                    if (![files moveItemAtURL:url toURL:destination error:&moveError]) {
                        [files removeItemAtURL:url error:nil];
                        [self reportError:@"Unable to save the verified model. Please try again."
                               generation:generation];
                        return;
                    }
                }
                [self reportProgress:1 message:@"Model verification complete." generation:generation];
                if (self->_generation.load() == generation && self.onReady) self.onReady(destination);
            });
        }
    });
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
    didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten
    totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (session != _session || downloadTask != _task) return;
    const double fraction = std::min(1.0, static_cast<double>(totalBytesWritten) / _expectedSize);
    if (fraction - _lastReportedFraction >= 0.01 || fraction == 1) {
        _lastReportedFraction = fraction;
        [self reportProgress:fraction
                     message:[NSString stringWithFormat:@"Downloading the model… %.0f%%", fraction * 100]
                  generation:_generation.load()];
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
    didFinishDownloadingToURL:(NSURL *)location {
    if (session != _session || downloadTask != _task) return;
    const uint64_t generation = _generation.load();
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)downloadTask.response;
    const NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? response.statusCode : 0;
    _task = nil;
    _session = nil;
    [session finishTasksAndInvalidate];
    if (status < 200 || status >= 300) {
        [self reportError:[NSString stringWithFormat:@"Model download failed (HTTP %ld). Please try again.", (long)status]
               generation:generation];
        return;
    }
    // NSURLSession removes its temporary file after this delegate returns.
    // Move it into Application Support now; verify on the utility queue before
    // atomically renaming it to the final filename on the same filesystem.
    NSURL *temporary = [[_modelURL URLByDeletingLastPathComponent]
        URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.partial", NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    if (![_files moveItemAtURL:location toURL:temporary error:&error]) {
        [self reportError:@"Unable to save the downloaded model. Check free disk space and folder permissions."
               generation:generation];
        return;
    }
    [self reportProgress:1 message:@"Download complete. Verifying SHA256…" generation:generation];
    [self verifyURL:temporary downloaded:YES trustStamp:NO generation:generation];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
    if (session != _session || task != _task || !error) return;
    const uint64_t generation = _generation.load();
    _task = nil;
    _session = nil;
    [session finishTasksAndInvalidate];
    [self reportError:[NSString stringWithFormat:@"Model download failed. %@ Please try again.", error.localizedDescription]
           generation:generation];
}

@end
