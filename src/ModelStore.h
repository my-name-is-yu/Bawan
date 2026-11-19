#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ModelStoreState) {
    ModelStoreIdle,
    ModelStoreChecking,
    ModelStoreDownloading,
    ModelStorePaused,
    ModelStoreVerifying,
    ModelStoreReady,
    ModelStoreFailed
};

struct ModelStoreSnapshot {
    ModelStoreState state = ModelStoreIdle;
    double progress = 0;
    NSString *_Nullable message = nil;
    // Set only when Ready.
    NSURL *_Nullable fileURL = nil;
    // Paused or Failed with bytes a resume can keep.
    bool resumable = false;
};

// Use on the main thread. onChange arrives there too, once per snapshot of the
// current preparation; hashing runs on a utility queue.
@interface ModelStore : NSObject
@property(nonatomic, readonly) ModelStoreSnapshot snapshot;
@property(nonatomic, copy, nullable) void (^onChange)(const ModelStoreSnapshot &snapshot);
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
