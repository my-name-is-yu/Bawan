#import "ModelDownloader.h"
#include "ModelDownload.h"
#include "ModelVerification.h"

#include <cerrno>
#include <cstdio>
#include <fcntl.h>
#include <memory>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

enum class PartialDownloadLockResult { Acquired, Busy, Failed };

class PartialDownloadLock {
public:
    PartialDownloadLock() = default;
    ~PartialDownloadLock() { release(); }
    PartialDownloadLock(const PartialDownloadLock &) = delete;
    PartialDownloadLock &operator=(const PartialDownloadLock &) = delete;

    PartialDownloadLockResult acquire(NSURL *url) {
        const int fd = open(url.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (fd < 0) return PartialDownloadLockResult::Failed;
        struct stat info {};
        if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode)) {
            close(fd);
            return PartialDownloadLockResult::Failed;
        }
        if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
            const int error = errno;
            close(fd);
            return error == EWOULDBLOCK ? PartialDownloadLockResult::Busy : PartialDownloadLockResult::Failed;
        }
        fd_ = fd;
        return PartialDownloadLockResult::Acquired;
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

@interface ModelDownloader () <NSURLSessionDataDelegate> {
    ModelDownloadHandler _handler;
    NSURLSession *_session;
    NSURLSessionDataTask *_task;
    NSURL *_partialURL;
    NSURL *_destinationURL;
    NSURL *_metadataURL;
    NSFileManager *_files;
    NSURL *_downloadURL;
    NSURLSessionConfiguration *_configuration;
    int64_t _expectedSize;
    NSString *_expectedSHA256;
    NSString *_etag;
    FILE *_partialFile;
    PartialDownloadLock _lock;
    int64_t _receivedBytes;
    int64_t _requestOffset;
    BOOL _retriedRange;
    double _lastReportedFraction;
}
@end

@implementation ModelDownloader

- (instancetype)initWithPartialURL:(NSURL *)partialURL destinationURL:(NSURL *)destinationURL
                       downloadURL:(NSURL *)downloadURL expectedSize:(int64_t)expectedSize
                            SHA256:(NSString *)expectedSHA256 fileManager:(NSFileManager *)files
              sessionConfiguration:(NSURLSessionConfiguration *)configuration {
    self = [super init];
    if (self) {
        _partialURL = partialURL;
        _destinationURL = destinationURL;
        _files = files;
        _metadataURL = [partialURL URLByAppendingPathExtension:@"plist"];
        _downloadURL = downloadURL;
        _configuration = configuration;
        _expectedSize = expectedSize;
        _expectedSHA256 = [expectedSHA256 copy];
        _lastReportedFraction = -1;
    }
    return self;
}

- (void)dealloc {
    if (_partialFile) std::fclose(_partialFile);
}

- (double)fraction { return static_cast<double>(_receivedBytes) / _expectedSize; }

- (bool)resumable {
    return _receivedBytes > 0 && _receivedBytes <= _expectedSize &&
        (_receivedBytes == _expectedSize || bawan::isStrongModelETag(_etag.UTF8String ?: ""));
}

- (std::optional<double>)resumeProgress {
    if (![self resumable]) return std::nullopt;
    return [self fraction];
}

- (void)emit:(const ModelDownloadEvent &)event {
    ModelDownloadHandler handler = _handler;
    if (handler) handler(event);
}

- (ModelDownloadOpening)open {
    const PartialDownloadLockResult lock = _lock.acquire([_partialURL URLByAppendingPathExtension:@"lock"]);
    const SavedModelPath destination = CheckSavedModelPath(_destinationURL);
    if (destination != SavedModelPath::Absent) {
        [self stop];
        if (auto issue = SavedModelPathIssue(destination)) return ModelFailed{*issue};
        return ModelDestinationPresent{};
    }
    if (lock != PartialDownloadLockResult::Acquired)
        return ModelFailed{lock == PartialDownloadLockResult::Busy ? ModelIssue::AnotherInstancePreparing
                                                                   : ModelIssue::LockUnavailable};
    if (![self loadPartial]) {
        [self stop];
        return ModelFailed{ModelIssue::OldPartialUnremovable};
    }
    if (_receivedBytes == _expectedSize) return ModelDownloaded{_partialURL};
    return ModelNeedsTransfer{};
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

- (void)stop {
    [self stopTransfer];
    _lock.release();
}

- (ModelPaused)pause {
    [self stop];
    return {[self fraction], [self resumable]};
}

- (std::optional<ModelIssue>)discard {
    [self stop];
    if ([self removePartial]) return std::nullopt;
    return ModelIssue::InvalidPartialUnremovable;
}

- (std::optional<ModelFailed>)install {
    std::optional<ModelFailed> failure;
    if ([_files moveItemAtURL:_partialURL toURL:_destinationURL error:nil]) {
        RemovePartialFile(_metadataURL);
        _receivedBytes = 0;
        _etag = nil;
    } else {
        failure = ModelFailed{SavedModelPathIssue(CheckSavedModelPath(_destinationURL)).value_or(ModelIssue::InstallFailed),
                              [self resumeProgress]};
    }
    [self stop];
    return failure;
}

- (BOOL)removePartial {
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
        info.st_size <= 0 || info.st_size > _expectedSize) return [self removePartial];
    NSDictionary *saved = ReadPartialMetadata(_metadataURL);
    if (![saved[@"url"] isEqual:_downloadURL.absoluteString] ||
        ![saved[@"size"] isKindOfClass:NSNumber.class] ||
        [saved[@"size"] longLongValue] != _expectedSize ||
        ![saved[@"sha256"] isEqual:_expectedSHA256] ||
        ![saved[@"etag"] isKindOfClass:NSString.class]) return [self removePartial];
    NSString *etag = saved[@"etag"];
    // A full file can be rehashed even without a validator. A prefix needs a
    // strong validator so If-Range cannot join bytes from different versions.
    if (info.st_size < _expectedSize && !bawan::isStrongModelETag(etag.UTF8String ?: ""))
        return [self removePartial];
    _receivedBytes = info.st_size;
    _etag = etag;
    return YES;
}

- (ModelDownloading)startWithHandler:(ModelDownloadHandler)handler {
    _handler = [handler copy];
    return [self beginTransfer];
}

- (ModelDownloading)beginTransfer {
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
    [_task resume];
    return {[self fraction], _requestOffset ? ModelDownloadStage::Resuming : ModelDownloadStage::Starting};
}

- (void)fail:(ModelFailure)failure discard:(BOOL)discard {
    [self stop];
    if (discard && ![self removePartial]) failure = ModelIssue::InvalidPartialUnremovable;
    [self emit:ModelFailed{failure, [self resumeProgress]}];
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
        [self fail:ModelIssue::InsecureRedirect discard:NO];
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
        if (![self removePartial]) {
            [self fail:ModelIssue::PartialRestartFailed discard:NO];
            return;
        }
        _retriedRange = YES;
        [self emit:[self beginTransfer]];
        return;
    }
    if (decision == bawan::DownloadResponse::Reject || decision == bawan::DownloadResponse::RetryFromStart ||
        (encoding.length && [encoding caseInsensitiveCompare:@"identity"] != NSOrderedSame)) {
        completionHandler(NSURLSessionResponseCancel);
        const BOOL incompatibleRange = http.statusCode == 200 || http.statusCode == 206 || http.statusCode == 416;
        if (incompatibleRange) [self fail:ModelIssue::IncompatibleResponse discard:YES];
        else [self fail:ModelHTTPFailed{static_cast<long>(http.statusCode)} discard:NO];
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
        [self fail:ModelIssue::PartialUnopenable discard:YES];
        return;
    }
    _partialFile = fdopen(descriptor, restart ? "wb" : "ab");
    if (!_partialFile) {
        close(descriptor);
        completionHandler(NSURLSessionResponseCancel);
        [self fail:ModelIssue::DownloadUnsaved discard:YES];
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
            [self fail:ModelIssue::ProgressUnsaved discard:YES];
            return;
        }
    }
    completionHandler(NSURLSessionResponseAllow);
    if (restart && _requestOffset) {
        _lastReportedFraction = -1;
        [self emit:ModelDownloading{0, ModelDownloadStage::Restarted}];
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (session != _session || dataTask != _task || !_partialFile || data.length == 0) return;
    if (data.length > static_cast<uint64_t>(_expectedSize - _receivedBytes)) {
        [self fail:ModelIssue::DownloadWrongSize discard:YES];
        return;
    }
    if (std::fwrite(data.bytes, 1, data.length, _partialFile) != data.length || std::fflush(_partialFile) != 0) {
        [self fail:ModelIssue::DiskFull discard:NO];
        return;
    }
    _receivedBytes += data.length;
    const double fraction = [self fraction];
    if (fraction - _lastReportedFraction >= 0.01 || fraction == 1) {
        _lastReportedFraction = fraction;
        [self emit:ModelDownloading{fraction, ModelDownloadStage::Receiving}];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (session != _session || task != _task) return;
    _task = nil;
    _session = nil;
    [session finishTasksAndInvalidate];
    if (_partialFile) {
        std::fclose(_partialFile);
        _partialFile = nullptr;
    }
    if (error || _receivedBytes != _expectedSize) {
        _lock.release();
        [self emit:ModelFailed{ModelInterrupted{error.localizedDescription}, [self resumeProgress]}];
        return;
    }
    [self emit:ModelDownloaded{_partialURL}];
}

@end
