#import "ModelStore.h"
#import "ModelDownloader.h"
#include "ModelVerification.h"

#include <atomic>
#include <sys/stat.h>
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

@interface ModelStore () <ModelDownloaderDelegate> {
    std::atomic<uint64_t> _generation;
    ModelDownloader *_downloader;
    NSURL *_modelURL;
    NSURL *_downloadURL;
    NSURLSessionConfiguration *_configuration;
    NSFileManager *_files;
    int64_t _expectedSize;
    NSString *_expectedSHA256;
    ModelStoreSnapshot _snapshot;
    dispatch_queue_t _verificationQueue;
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
    [_downloader stop];
}

- (ModelStoreSnapshot)snapshot { return _snapshot; }

- (void)publish:(const ModelStoreSnapshot &)snapshot generation:(uint64_t)generation {
    if (_generation.load() != generation) return;
    _snapshot = snapshot;
    if (self.onChange) self.onChange(_snapshot);
}

- (void)stop {
    ++_generation;
    [_downloader stop];
}

- (void)cancel {
    NSAssert(NSThread.isMainThread, @"ModelStore must be used on the main thread");
    [self stop];
    [self publish:{} generation:_generation.load()];
}

- (void)pause {
    NSAssert(NSThread.isMainThread, @"ModelStore must be used on the main thread");
    if (_snapshot.state != ModelStoreDownloading) return;
    [self stop];
    const bool resumable = _downloader.canResume;
    [self publish:{ModelStorePaused, static_cast<double>(_downloader.receivedBytes) / _expectedSize,
                   resumable ? @"Model download paused. Resume to continue."
                             : @"Model download paused. Resume to restart the download.",
                   nil, resumable}
       generation:_generation.load()];
}

- (void)resume {
    NSAssert(NSThread.isMainThread, @"ModelStore must be used on the main thread");
    if (_snapshot.state == ModelStorePaused || _snapshot.state == ModelStoreFailed) [self prepare];
}

- (void)prepare { [self prepareTrustingVerifiedModel:YES]; }
- (void)revalidate { [self prepareTrustingVerifiedModel:NO]; }

- (void)prepareTrustingVerifiedModel:(BOOL)trustStamp {
    NSAssert(NSThread.isMainThread, @"ModelStore must be used on the main thread");
    [self stop];
    const uint64_t generation = _generation.load();
    _downloader = nil;
    [self publish:{ModelStoreChecking} generation:generation];
    if (_generation.load() != generation) return;
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
    _downloader = [[ModelDownloader alloc]
        initWithPartialURL:[directory URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.partial", ModelFilename]]
               downloadURL:_downloadURL expectedSize:_expectedSize SHA256:_expectedSHA256
      sessionConfiguration:_configuration delegate:self];
    bool hasSavedModel;
    NSString *pathError = CheckSavedModelPath(_modelURL, &hasSavedModel);
    if (pathError) {
        [self reportError:pathError generation:generation];
        return;
    }
    if (!hasSavedModel) {
        const PartialDownloadLockResult lock = [_downloader lockPartial];
        pathError = CheckSavedModelPath(_modelURL, &hasSavedModel);
        if (pathError) {
            [self reportError:pathError generation:generation];
            return;
        }
        if (lock != PartialDownloadLockAcquired && !hasSavedModel) {
            [self reportError:lock == PartialDownloadLockBusy
                ? @"Another Bawan instance is preparing the model. Pause it or wait for it to finish, then try again."
                : @"Unable to lock the model download. Check the folder permissions and try again."
                generation:generation];
            return;
        }
    }
    if (hasSavedModel) {
        [self publish:{ModelStoreVerifying, 0, @"Checking the saved model…"} generation:generation];
        if (_generation.load() == generation)
            [self verifyURL:_modelURL downloaded:NO trustStamp:trustStamp generation:generation];
        return;
    }
    if (![_downloader loadPartial]) {
        [self reportError:@"Unable to remove the old partial download. Check for conflicting items or folder permissions and try again."
              generation:generation];
        return;
    }
    if (_downloader.complete) {
        [self finishDownload:generation];
        return;
    }
    [_downloader start];
}

- (void)reportError:(NSString *)message generation:(uint64_t)generation {
    if (_generation.load() != generation) return;
    [_downloader stop];
    const bool resumable = _downloader.canResume;
    [self publish:{ModelStoreFailed, resumable ? _snapshot.progress : 0, message, nil, resumable}
       generation:generation];
}

- (void)finishDownload:(uint64_t)generation {
    [self publish:{ModelStoreVerifying, 1, @"Download complete. Verifying SHA256…"} generation:generation];
    if (_generation.load() == generation)
        [self verifyURL:_downloader.partialURL downloaded:YES trustStamp:NO generation:generation];
}

- (void)verifyURL:(NSURL *)url downloaded:(BOOL)downloaded trustStamp:(BOOL)trustStamp
        generation:(uint64_t)generation {
    NSURL *destination = _modelURL;
    ModelDownloader *downloader = _downloader;
    dispatch_async(_verificationQueue, ^{
        @autoreleasepool {
            NSString *reason = nil;
            struct stat verified {};
            const Verification result = VerifyModel(url, self->_generation, generation,
                self->_expectedSize, self->_expectedSHA256.UTF8String, trustStamp, verified, &reason);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self->_generation.load() != generation || result == Verification::Cancelled) return;
                if (result == Verification::Collision && !downloaded) {
                    [self reportError:ModelPathCollision generation:generation];
                    return;
                }
                if (result != Verification::Valid) {
                    NSString *failureReason = reason ?: @"Model verification failed.";
                    if (downloaded) {
                        if (![downloader discardPartial])
                            failureReason = @"Unable to remove the invalid partial download. Check the folder permissions.";
                        else
                            failureReason = [failureReason stringByAppendingString:@" The partial download was discarded."];
                    } else if (result == Verification::Invalid) {
                        NSString *cleanupError = RemoveInvalidSavedModel(url, verified);
                        if (cleanupError) {
                            [self reportError:cleanupError generation:generation];
                            return;
                        }
                    }
                    [self reportError:[failureReason stringByAppendingString:@" Please try again to download the model."]
                           generation:generation];
                    return;
                }
                if (downloaded) {
                    if (![self->_files moveItemAtURL:url toURL:destination error:nil]) {
                        NSString *pathError = CheckSavedModelPath(destination);
                        [self reportError:pathError ?: @"Unable to save the verified model. Check the folder permissions and try again."
                               generation:generation];
                        return;
                    }
                    [downloader forgetInstalledPartial];
                }
                [downloader stop];
                [self publish:{ModelStoreReady, 1, nil, destination} generation:generation];
            });
        }
    });
}

- (void)modelDownloader:(ModelDownloader *)downloader didProgress:(double)fraction message:(NSString *)message {
    [self publish:{ModelStoreDownloading, fraction, message} generation:_generation.load()];
}

- (void)modelDownloader:(ModelDownloader *)downloader didFailWithMessage:(NSString *)message {
    [self reportError:message generation:_generation.load()];
}

- (void)modelDownloaderDidFinish:(ModelDownloader *)downloader {
    [self finishDownload:_generation.load()];
}

@end
