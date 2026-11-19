#import <Foundation/Foundation.h>

#include "ModelStoreSnapshot.h"

NS_ASSUME_NONNULL_BEGIN

struct ModelDownloaded {
    NSURL *url;
};
struct ModelDestinationPresent {};
struct ModelNeedsTransfer {};

using ModelDownloadOpening = std::variant<ModelFailed, ModelDestinationPresent, ModelDownloaded, ModelNeedsTransfer>;
using ModelDownloadEvent = std::variant<ModelDownloading, ModelDownloaded, ModelFailed>;
typedef void (^ModelDownloadHandler)(const ModelDownloadEvent &event);

// Owns the partial file next to the destination: its lock, resume metadata,
// transfer and installation. Use on the main thread; events arrive there too.
@interface ModelDownloader : NSObject
- (instancetype)initWithPartialURL:(NSURL *)partialURL destinationURL:(NSURL *)destinationURL
                       downloadURL:(NSURL *)downloadURL expectedSize:(int64_t)expectedSize
                            SHA256:(NSString *)expectedSHA256 fileManager:(NSFileManager *)files
              sessionConfiguration:(NSURLSessionConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (ModelDownloadOpening)open;
- (ModelDownloading)startWithHandler:(ModelDownloadHandler)handler;
- (ModelPaused)pause;
- (void)stop;
- (std::optional<ModelFailed>)install;
- (std::optional<ModelIssue>)discard;
@end

NS_ASSUME_NONNULL_END
