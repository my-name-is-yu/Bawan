#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ModelStoreState) {
    ModelStoreIdle,
    ModelStoreDownloading,
    ModelStorePaused,
    ModelStoreVerifying,
    ModelStoreReady,
    ModelStoreFailed
};

// Use on the main thread. Callbacks arrive there too; hashing runs on a utility queue.
@interface ModelStore : NSObject
@property(nonatomic, readonly) ModelStoreState state;
@property(nonatomic, readonly) BOOL canResume;
@property(nonatomic, copy, nullable) void (^onStateChange)(ModelStoreState state);
@property(nonatomic, copy, nullable) void (^onProgress)(double fraction, NSString *message);
@property(nonatomic, copy, nullable) void (^onReady)(NSURL *fileURL);
@property(nonatomic, copy, nullable) void (^onError)(NSString *message);
// Trusts a saved model whose size, inode and modification time still match
// its last successful SHA256 verification.
- (void)prepare;
// Always rehashes a saved model.
- (void)revalidate;
// Pause preserves received bytes. Resume uses a validated partial when available.
- (void)pause;
- (void)resume;
// Stops work (including verification) without deleting the partial, e.g. on quit.
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
