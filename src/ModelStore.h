#import <Foundation/Foundation.h>

#include "ModelStoreSnapshot.h"

NS_ASSUME_NONNULL_BEGIN

// Use on the main thread. Each call publishes its resulting snapshot before it
// returns; later snapshots of the same preparation also arrive on the main thread.
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
