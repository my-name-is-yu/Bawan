#import "ModelStore.h"
#include "ModelDownload.h"

#include <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <memory>
#include <fcntl.h>
#include <unistd.h>
#include <string>
#include <sys/file.h>
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

class PartialDownloadLock {
public:
    enum class Result { Acquired, Busy, Failed };

    PartialDownloadLock() = default;
    ~PartialDownloadLock() { release(); }
    PartialDownloadLock(const PartialDownloadLock &) = delete;
    PartialDownloadLock &operator=(const PartialDownloadLock &) = delete;

    Result acquire(NSURL *url) {
        const int fd = open(url.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (fd < 0) return Result::Failed;
        struct stat info {};
        if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode)) {
            close(fd);
            return Result::Failed;
        }
        if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
            const int error = errno;
            close(fd);
            return error == EWOULDBLOCK ? Result::Busy : Result::Failed;
        }
        fd_ = fd;
        return Result::Acquired;
    }

    void release() {
        if (fd_ < 0) return;
        // Keep the file so every instance locks the same inode. Closing releases the lock.
        close(fd_);
        fd_ = -1;
    }

private:
    int fd_ = -1;
};

static const char VerifiedAttribute[] = "local.bawan.verified-sha256";

static bool RemovePartialFile(NSURL *url) {
    // Unlike NSFileManager removal, unlink never descends into a directory.
    return unlink(url.fileSystemRepresentation) == 0 || errno == ENOENT;
}

static NSDictionary *ReadPartialMetadata(NSURL *url) {
    constexpr off_t MaxMetadataBytes = 64 * 1024;
    const int descriptor = open(url.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (descriptor < 0) return nil;
    struct stat info {};
    if (fstat(descriptor, &info) != 0 || !S_ISREG(info.st_mode) ||
        info.st_size <= 0 || info.st_size > MaxMetadataBytes) {
        close(descriptor);
        return nil;
    }
    std::unique_ptr<FILE, decltype(&std::fclose)> file(fdopen(descriptor, "rb"), &std::fclose);
    if (!file) {
        close(descriptor);
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:static_cast<NSUInteger>(info.st_size)];
    if (std::fread(data.mutableBytes, 1, data.length, file.get()) != data.length) return nil;
    id metadata = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:nil error:nil];
    return [metadata isKindOfClass:NSDictionary.class] ? metadata : nil;
}

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

@interface ModelStore () <NSURLSessionDataDelegate> {
    std::atomic<uint64_t> _generation;
    NSURLSession *_session;
    NSURLSessionDataTask *_task;
    NSURL *_modelURL;
    NSURL *_partialURL;
    NSURL *_metadataURL;
    NSURL *_downloadURL;
    NSURLSessionConfiguration *_configuration;
    NSFileManager *_files;
    int64_t _expectedSize;
    NSString *_expectedSHA256;
    NSString *_etag;
    FILE *_partialFile;
    PartialDownloadLock _partialLock;
    int64_t _receivedBytes;
    int64_t _requestOffset;
    BOOL _retriedRange;
    ModelStoreState _state;
    dispatch_queue_t _verificationQueue;
    double _lastReportedFraction;
}
- (instancetype)initWithFileManager:(NSFileManager *)files expectedSize:(int64_t)expectedSize
                            SHA256:(NSString *)expectedSHA256;
- (instancetype)initWithFileManager:(NSFileManager *)files expectedSize:(int64_t)expectedSize
                            SHA256:(NSString *)expectedSHA256 downloadURL:(NSURL *)downloadURL
              sessionConfiguration:(NSURLSessionConfiguration *)configuration;
@end

@implementation ModelStore

- (instancetype)init {
    return [self initWithFileManager:NSFileManager.defaultManager expectedSize:ModelSize
                             SHA256:@(ModelSHA256)];
}

- (instancetype)initWithFileManager:(NSFileManager *)files expectedSize:(int64_t)expectedSize
                            SHA256:(NSString *)expectedSHA256 {
    return [self initWithFileManager:files expectedSize:expectedSize SHA256:expectedSHA256
        downloadURL:[NSURL URLWithString:ModelDownloadURL]
        sessionConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
}

- (instancetype)initWithFileManager:(NSFileManager *)files expectedSize:(int64_t)expectedSize
                            SHA256:(NSString *)expectedSHA256 downloadURL:(NSURL *)downloadURL
              sessionConfiguration:(NSURLSessionConfiguration *)configuration {
    self = [super init];
    if (self) {
        _files = files;
        _expectedSize = expectedSize;
        _expectedSHA256 = [expectedSHA256 copy];
        _downloadURL = downloadURL;
        _configuration = [configuration copy];
        _generation.store(0);
        _verificationQueue = dispatch_queue_create("local.bawan.model-verification",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    }
    return self;
}

- (void)dealloc {
    if (_partialFile) std::fclose(_partialFile);
}

- (ModelStoreState)state { return _state; }

- (BOOL)canResume {
    return _receivedBytes > 0 && _receivedBytes <= _expectedSize &&
        (_receivedBytes == _expectedSize || bawan::isStrongModelETag(_etag.UTF8String ?: ""));
}

- (void)setState:(ModelStoreState)state {
    _state = state;
    if (self.onStateChange) self.onStateChange(state);
}

- (void)stopTransfer {
    [_task cancel];
    [_session invalidateAndCancel];
    _task = nil;
    _session = nil;
    if (_partialFile) {
        std::fclose(_partialFile);
        _partialFile = nullptr;
    }
}

- (void)cancel {
    NSAssert(NSThread.isMainThread, @"ModelStore must be used on the main thread");
    ++_generation;
    [self stopTransfer];
    _partialLock.release();
    [self setState:ModelStoreIdle];
}

- (void)pause {
    NSAssert(NSThread.isMainThread, @"ModelStore must be used on the main thread");
    if (_state != ModelStoreDownloading) return;
    ++_generation;
    const uint64_t generation = _generation.load();
    [self stopTransfer];
    _partialLock.release();
    [self setState:ModelStorePaused];
    [self reportProgress:static_cast<double>(_receivedBytes) / _expectedSize
        message:self.canResume ? @"Model download paused. Resume to continue."
                               : @"Model download paused. Resume to restart the download."
        generation:generation];
}

- (void)resume {
    NSAssert(NSThread.isMainThread, @"ModelStore must be used on the main thread");
    if (_state == ModelStorePaused || _state == ModelStoreFailed) [self prepare];
}

- (void)prepare { [self prepareTrustingVerifiedModel:YES]; }
- (void)revalidate { [self prepareTrustingVerifiedModel:NO]; }

- (BOOL)discardPartial {
    const bool removedPartial = RemovePartialFile(_partialURL);
    const bool removedMetadata = RemovePartialFile(_metadataURL);
    _receivedBytes = 0;
    _etag = nil;
    return removedPartial && removedMetadata;
}

- (BOOL)loadPartial {
    _receivedBytes = 0;
    _etag = nil;
    struct stat info {};
    if (lstat(_partialURL.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode) ||
        info.st_size <= 0 || info.st_size > _expectedSize) return [self discardPartial];
    NSDictionary *saved = ReadPartialMetadata(_metadataURL);
    if (![saved[@"url"] isEqual:_downloadURL.absoluteString] ||
        ![saved[@"size"] isKindOfClass:NSNumber.class] ||
        [saved[@"size"] longLongValue] != _expectedSize ||
        ![saved[@"sha256"] isEqual:_expectedSHA256] ||
        ![saved[@"etag"] isKindOfClass:NSString.class]) return [self discardPartial];
    NSString *etag = saved[@"etag"];
    // A full file can be rehashed even without a validator. A prefix needs a
    // strong validator so If-Range cannot join bytes from different versions.
    if (info.st_size < _expectedSize && !bawan::isStrongModelETag(etag.UTF8String ?: ""))
        return [self discardPartial];
    _receivedBytes = info.st_size;
    _etag = etag;
    return YES;
}

- (void)prepareTrustingVerifiedModel:(BOOL)trustStamp {
    NSAssert(NSThread.isMainThread, @"ModelStore must be used on the main thread");
    [self cancel];
    const uint64_t generation = _generation.load();
    _receivedBytes = 0;
    _etag = nil;
    _lastReportedFraction = -1;
    _retriedRange = NO;
    NSError *error = nil;
    NSURL *support = [_files URLForDirectory:NSApplicationSupportDirectory
                                   inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
    NSURL *directory = [support URLByAppendingPathComponent:@"local.bawan.Bawan" isDirectory:YES];
    if (!support || ![_files createDirectoryAtURL:directory withIntermediateDirectories:YES
                                      attributes:nil error:&error]) {
        [self reportError:@"Unable to create the model folder." generation:generation];
        return;
    }
    _modelURL = [directory URLByAppendingPathComponent:ModelFilename];
    _partialURL = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.partial", ModelFilename]];
    _metadataURL = [_partialURL URLByAppendingPathExtension:@"plist"];
    BOOL hasSavedModel = [_files fileExistsAtPath:_modelURL.path];
    if (!hasSavedModel) {
        // Own the shared partial from inspection through transfer and installation.
        const auto lock = _partialLock.acquire([_partialURL URLByAppendingPathExtension:@"lock"]);
        // A peer may have installed the model while we were acquiring the lock.
        hasSavedModel = [_files fileExistsAtPath:_modelURL.path];
        if (lock != PartialDownloadLock::Result::Acquired && !hasSavedModel) {
            [self reportError:lock == PartialDownloadLock::Result::Busy
                ? @"Another Bawan instance is preparing the model. Pause it or wait for it to finish, then try again."
                : @"Unable to lock the model download. Check the folder permissions and try again."
                generation:generation];
            return;
        }
    }
    if (hasSavedModel) {
        [self setState:ModelStoreVerifying];
        [self reportProgress:0 message:@"Checking the saved model…" generation:generation];
        if (_generation.load() == generation)
            [self verifyURL:_modelURL downloaded:NO trustStamp:trustStamp generation:generation];
        return;
    }
    if (![self loadPartial]) {
        [self reportError:@"Unable to remove the old partial download. Check for conflicting items or folder permissions and try again."
              generation:generation];
        return;
    }
    if (_receivedBytes == _expectedSize) {
        [self finishDownload:generation];
        return;
    }
    [self startDownload:generation];
}

- (void)startDownload:(uint64_t)generation {
    NSURLSessionConfiguration *configuration = [_configuration copy];
    configuration.URLCache = nil;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest = 60;
    configuration.timeoutIntervalForResource = 60 * 60;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_downloadURL];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    _requestOffset = _receivedBytes;
    if (_requestOffset) {
        [request setValue:[NSString stringWithFormat:@"bytes=%lld-", (long long)_requestOffset]
            forHTTPHeaderField:@"Range"];
        [request setValue:_etag forHTTPHeaderField:@"If-Range"];
    }
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self
                                      delegateQueue:NSOperationQueue.mainQueue];
    _task = [_session dataTaskWithRequest:request];
    [self setState:ModelStoreDownloading];
    [self reportProgress:static_cast<double>(_receivedBytes) / _expectedSize
        message:_requestOffset ? @"Resuming the model download…" : @"Downloading the model…"
        generation:generation];
    if (_generation.load() == generation) [_task resume];
}

- (void)reportProgress:(double)fraction message:(NSString *)message generation:(uint64_t)generation {
    if (_generation.load() == generation && self.onProgress) self.onProgress(fraction, message);
}

- (void)reportError:(NSString *)message generation:(uint64_t)generation {
    if (_generation.load() != generation) return;
    _partialLock.release();
    [self setState:ModelStoreFailed];
    if (_generation.load() == generation && self.onError) self.onError(message);
}

- (void)failTransfer:(NSString *)message discard:(BOOL)discard generation:(uint64_t)generation {
    [self stopTransfer];
    if (discard && ![self discardPartial])
        message = @"Unable to remove the invalid partial download. Check the folder permissions and try again.";
    [self reportError:message generation:generation];
}

- (void)finishDownload:(uint64_t)generation {
    [self setState:ModelStoreVerifying];
    [self reportProgress:1 message:@"Download complete. Verifying SHA256…" generation:generation];
    if (_generation.load() == generation)
        [self verifyURL:_partialURL downloaded:YES trustStamp:NO generation:generation];
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
                if (self->_generation.load() != generation || result == Verification::Cancelled) return;
                if (result != Verification::Valid) {
                    NSString *failureReason = reason ?: @"Model verification failed.";
                    if (downloaded) {
                        if (![self discardPartial])
                            failureReason = @"Unable to remove the invalid partial download. Check the folder permissions.";
                        else
                            failureReason = [failureReason stringByAppendingString:@" The partial download was discarded."];
                    } else if (result == Verification::Invalid) {
                        if (![self->_files removeItemAtURL:url error:nil])
                            failureReason = @"Unable to remove the invalid model file. Check the folder permissions.";
                    }
                    [self reportError:[failureReason stringByAppendingString:@" Please try again to download the model."]
                           generation:generation];
                    return;
                }
                if (downloaded) {
                    if (![self->_files moveItemAtURL:url toURL:destination error:nil]) {
                        [self reportError:@"Unable to save the verified model. Check the folder permissions and try again."
                               generation:generation];
                        return;
                    }
                    RemovePartialFile(self->_metadataURL);
                    self->_receivedBytes = 0;
                    self->_etag = nil;
                }
                self->_partialLock.release();
                [self setState:ModelStoreReady];
                [self reportProgress:1 message:@"Model verification complete." generation:generation];
                if (self->_generation.load() == generation && self.onReady) self.onReady(destination);
            });
        }
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    if (session != _session || task != _task) {
        completionHandler(nil);
        return;
    }
    if (![request.URL.scheme.lowercaseString isEqualToString:@"https"]) {
        completionHandler(nil);
        [self failTransfer:@"The server redirected the model download to an insecure address. Please try again."
                  discard:NO generation:_generation.load()];
        return;
    }
    NSMutableURLRequest *redirect = [request mutableCopy];
    for (NSString *header in @[@"Range", @"If-Range", @"Accept-Encoding"])
        [redirect setValue:[task.originalRequest valueForHTTPHeaderField:header] forHTTPHeaderField:header];
    completionHandler(redirect);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    if (session != _session || dataTask != _task) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    const uint64_t generation = _generation.load();
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    NSString *contentRange = [http valueForHTTPHeaderField:@"Content-Range"] ?: @"";
    NSString *etag = [http valueForHTTPHeaderField:@"ETag"] ?: @"";
    NSString *encoding = [http valueForHTTPHeaderField:@"Content-Encoding"];
    const auto decision = bawan::modelDownloadResponse((int)http.statusCode, _requestOffset,
        _expectedSize, contentRange.UTF8String, _etag.UTF8String ?: "", etag.UTF8String,
        response.expectedContentLength);
    if (decision == bawan::DownloadResponse::RetryFromStart && !_retriedRange) {
        completionHandler(NSURLSessionResponseCancel);
        [self stopTransfer];
        if (![self discardPartial]) {
            [self reportError:@"Unable to restart the partial download. Check the folder permissions and try again."
                  generation:generation];
            return;
        }
        _retriedRange = YES;
        [self startDownload:generation];
        return;
    }
    if (decision == bawan::DownloadResponse::Reject || decision == bawan::DownloadResponse::RetryFromStart ||
        (encoding.length && [encoding caseInsensitiveCompare:@"identity"] != NSOrderedSame)) {
        completionHandler(NSURLSessionResponseCancel);
        // Service errors preserve a good prefix; an incompatible Range response
        // must be discarded so the next explicit retry can start from zero.
        const BOOL discard = http.statusCode == 200 || http.statusCode == 206 || http.statusCode == 416;
        NSString *message = discard ? @"The server returned an incompatible model download. The partial download was discarded. Please try again."
            : [NSString stringWithFormat:@"Model download failed (HTTP %ld). %@", (long)http.statusCode,
                self.canResume ? @"Resume to continue the download." : @"Please try again."];
        [self failTransfer:message discard:discard generation:generation];
        return;
    }
    const BOOL restart = decision == bawan::DownloadResponse::Restart || _requestOffset == 0;
    const int flags = O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK |
        (restart ? (O_CREAT | O_TRUNC) : O_APPEND);
    int descriptor = open(_partialURL.fileSystemRepresentation, flags, 0600);
    struct stat info {};
    if (descriptor < 0 || fstat(descriptor, &info) != 0 || !S_ISREG(info.st_mode) ||
        info.st_size != (restart ? 0 : _requestOffset)) {
        if (descriptor >= 0) close(descriptor);
        completionHandler(NSURLSessionResponseCancel);
        [self failTransfer:@"Unable to open the partial download. Check disk space and folder permissions, then try again."
                  discard:YES generation:generation];
        return;
    }
    _partialFile = fdopen(descriptor, restart ? "wb" : "ab");
    if (!_partialFile) {
        close(descriptor);
        completionHandler(NSURLSessionResponseCancel);
        [self failTransfer:@"Unable to save the model download. Please try again." discard:YES generation:generation];
        return;
    }
    _receivedBytes = restart ? 0 : _requestOffset;
    if (restart) {
        _etag = bawan::isStrongModelETag(etag.UTF8String) ? [etag copy] : @"";
        NSDictionary *metadata = @{@"url":_downloadURL.absoluteString, @"size":@(_expectedSize),
            @"sha256":_expectedSHA256, @"etag":_etag};
        NSData *saved = [NSPropertyListSerialization dataWithPropertyList:metadata
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        if (!saved || ![saved writeToURL:_metadataURL options:NSDataWritingAtomic error:nil]) {
            completionHandler(NSURLSessionResponseCancel);
            [self failTransfer:@"Unable to save download progress. Check disk space and folder permissions, then try again."
                      discard:YES generation:generation];
            return;
        }
    }
    completionHandler(NSURLSessionResponseAllow);
    if (restart && _requestOffset) {
        _lastReportedFraction = -1;
        [self reportProgress:0 message:@"The server restarted the download from the beginning."
                  generation:generation];
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (session != _session || dataTask != _task || !_partialFile || data.length == 0) return;
    const uint64_t generation = _generation.load();
    if (data.length > static_cast<uint64_t>(_expectedSize - _receivedBytes)) {
        [self failTransfer:@"The model download has an incorrect size. The partial download was discarded. Please try again."
                  discard:YES generation:generation];
        return;
    }
    if (std::fwrite(data.bytes, 1, data.length, _partialFile) != data.length || std::fflush(_partialFile) != 0) {
        [self failTransfer:@"Unable to save the model download. Check free disk space and try again."
                  discard:NO generation:generation];
        return;
    }
    _receivedBytes += data.length;
    const double fraction = static_cast<double>(_receivedBytes) / _expectedSize;
    if (fraction - _lastReportedFraction >= 0.01 || fraction == 1) {
        _lastReportedFraction = fraction;
        [self reportProgress:fraction
            message:[NSString stringWithFormat:@"Downloading the model… %.0f%%", fraction * 100]
            generation:generation];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (session != _session || task != _task) return;
    const uint64_t generation = _generation.load();
    _task = nil;
    _session = nil;
    [session finishTasksAndInvalidate];
    if (_partialFile) {
        std::fclose(_partialFile);
        _partialFile = nullptr;
    }
    if (error || _receivedBytes != _expectedSize) {
        NSString *message = [NSString stringWithFormat:@"Model download interrupted. %@ %@",
            error.localizedDescription ?: @"The server sent an incomplete file.",
            self.canResume ? @"Resume to continue the download." : @"Please try again."];
        [self reportError:message generation:generation];
        return;
    }
    [self finishDownload:generation];
}

@end
