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

@interface ModelStore () {
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
    if (self.onChange) self.onChange(snapshot);
}

- (uint64_t)restart {
    [_downloader stop];
    return ++_generation;
}

- (void)cancel {
    NSAssert(NSThread.isMainThread, @"ModelStore must be used on the main thread");
    [self publish:ModelIdle{} generation:[self restart]];
}

- (void)pause {
    NSAssert(NSThread.isMainThread, @"ModelStore must be used on the main thread");
    if (!std::holds_alternative<ModelDownloading>(_snapshot)) return;
    [self publish:[_downloader pause] generation:++_generation];
}

- (void)resume {
    NSAssert(NSThread.isMainThread, @"ModelStore must be used on the main thread");
    if (std::holds_alternative<ModelPaused>(_snapshot) || std::holds_alternative<ModelFailed>(_snapshot))
        [self prepare];
}

- (void)prepare { [self prepareTrustingVerifiedModel:YES]; }
- (void)revalidate { [self prepareTrustingVerifiedModel:NO]; }

- (void)prepareTrustingVerifiedModel:(BOOL)trustStamp {
    NSAssert(NSThread.isMainThread, @"ModelStore must be used on the main thread");
    const uint64_t generation = [self restart];
    _downloader = nil;
    [self publish:[self beginPreparation:trustStamp generation:generation] generation:generation];
}

- (ModelStoreSnapshot)beginPreparation:(BOOL)trustStamp generation:(uint64_t)generation {
    NSURL *support = [_files URLForDirectory:NSApplicationSupportDirectory
                                   inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *directory = [support URLByAppendingPathComponent:@"local.bawan.Bawan" isDirectory:YES];
    if (!support || ![_files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil])
        return ModelFailed{ModelIssue::FolderUnavailable};
    _modelURL = [directory URLByAppendingPathComponent:ModelFilename];
    const SavedModelPath saved = CheckSavedModelPath(_modelURL);
    if (auto issue = SavedModelPathIssue(saved)) return ModelFailed{*issue};
    if (saved == SavedModelPath::Present) return [self verifySavedModel:trustStamp generation:generation];

    _downloader = [[ModelDownloader alloc]
        initWithPartialURL:[directory URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.partial", ModelFilename]]
            destinationURL:_modelURL downloadURL:_downloadURL expectedSize:_expectedSize SHA256:_expectedSHA256
               fileManager:_files sessionConfiguration:_configuration];
    const ModelDownloadOpening opening = [_downloader open];
    if (auto *failed = std::get_if<ModelFailed>(&opening)) return *failed;
    if (auto *downloaded = std::get_if<ModelDownloaded>(&opening))
        return [self verifyDownload:downloaded->url generation:generation];
    if (std::holds_alternative<ModelDestinationPresent>(opening)) {
        _downloader = nil;
        return [self verifySavedModel:trustStamp generation:generation];
    }
    __weak ModelStore *weakSelf = self;
    return [_downloader startWithHandler:^(const ModelDownloadEvent &event) {
        [weakSelf downloadDidChange:event generation:generation];
    }];
}

- (void)downloadDidChange:(const ModelDownloadEvent &)event generation:(uint64_t)generation {
    if (auto *downloaded = std::get_if<ModelDownloaded>(&event)) {
        if (_generation.load() == generation)
            [self publish:[self verifyDownload:downloaded->url generation:generation] generation:generation];
    } else if (auto *downloading = std::get_if<ModelDownloading>(&event)) {
        [self publish:*downloading generation:generation];
    } else {
        [self publish:std::get<ModelFailed>(event) generation:generation];
    }
}

- (ModelStoreSnapshot)verifySavedModel:(BOOL)trustStamp generation:(uint64_t)generation {
    NSURL *url = _modelURL;
    [self verify:url trustStamp:trustStamp generation:generation then:^ModelStoreSnapshot(const VerificationResult &result) {
        switch (result.outcome) {
            case VerificationOutcome::Valid: return ModelReady{url};
            case VerificationOutcome::Occupied: return ModelFailed{ModelIssue::PathOccupied};
            case VerificationOutcome::Invalid:
                if (auto issue = RemoveSavedModelIfUnchanged(url, result.file)) return ModelFailed{*issue};
                break;
            case VerificationOutcome::Unchecked:
            case VerificationOutcome::Cancelled: break;
        }
        return ModelFailed{ModelCheckFailed{result.issue, ModelFileKind::Saved}};
    }];
    return ModelVerifying{ModelFileKind::Saved};
}

- (ModelStoreSnapshot)verifyDownload:(NSURL *)url generation:(uint64_t)generation {
    ModelDownloader *downloader = _downloader;
    NSURL *destination = _modelURL;
    [self verify:url trustStamp:NO generation:generation then:^ModelStoreSnapshot(const VerificationResult &result) {
        if (result.outcome == VerificationOutcome::Valid) {
            if (auto failed = [downloader install]) return *failed;
            return ModelReady{destination};
        }
        if (auto issue = [downloader discard]) return ModelFailed{*issue};
        return ModelFailed{ModelCheckFailed{result.issue, ModelFileKind::Download}};
    }];
    return ModelVerifying{ModelFileKind::Download};
}

- (void)verify:(NSURL *)url trustStamp:(BOOL)trustStamp generation:(uint64_t)generation
          then:(ModelStoreSnapshot (^)(const VerificationResult &result))finish {
    dispatch_async(_verificationQueue, ^{
        @autoreleasepool {
            const VerificationResult result = VerifyModel(url, self->_generation, generation,
                self->_expectedSize, self->_expectedSHA256.UTF8String,
                trustStamp ? StampUse::TrustUnchanged : StampUse::Rehash);
            if (result.outcome == VerificationOutcome::Cancelled) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self->_generation.load() == generation) [self publish:finish(result) generation:generation];
            });
        }
    });
}

@end
