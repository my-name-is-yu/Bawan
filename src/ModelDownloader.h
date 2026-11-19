#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ModelDownloader;

typedef NS_ENUM(NSInteger, PartialDownloadLockResult) {
    PartialDownloadLockAcquired,
    PartialDownloadLockBusy,
    PartialDownloadLockFailed
};

// Use on the main thread. Messages arrive there, synchronously from the downloader's
// own methods, and the delegate may stop the downloader from any of them.
@protocol ModelDownloaderDelegate <NSObject>
- (void)modelDownloader:(ModelDownloader *)downloader didProgress:(double)fraction message:(NSString *)message;
- (void)modelDownloader:(ModelDownloader *)downloader didFailWithMessage:(NSString *)message;
- (void)modelDownloaderDidFinish:(ModelDownloader *)downloader;
@end

@interface ModelDownloader : NSObject
@property(nonatomic, readonly) NSURL *partialURL;
@property(nonatomic, readonly) int64_t receivedBytes;
@property(nonatomic, readonly) BOOL canResume;
@property(nonatomic, readonly, getter=isComplete) BOOL complete;

- (instancetype)initWithPartialURL:(NSURL *)partialURL downloadURL:(NSURL *)downloadURL
                      expectedSize:(int64_t)expectedSize SHA256:(NSString *)expectedSHA256
              sessionConfiguration:(NSURLSessionConfiguration *)configuration
                          delegate:(id<ModelDownloaderDelegate>)delegate NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (PartialDownloadLockResult)lockPartial;
// Adopts a saved partial whose metadata matches this download, otherwise removes it.
// Returns NO when the partial cannot be removed.
- (BOOL)loadPartial;
- (void)start;
// Stops the transfer and releases the lock. Received bytes stay on disk.
- (void)stop;
- (BOOL)discardPartial;
- (void)forgetInstalledPartial;
@end

NS_ASSUME_NONNULL_END
