#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Call prepare/cancel and set callbacks on the main thread. All callbacks also
// arrive on the main thread; hashing and file reads run on a utility queue.
@interface ModelStore : NSObject
@property(nonatomic, copy, nullable) void (^onProgress)(double fraction, NSString *message);
@property(nonatomic, copy, nullable) void (^onReady)(NSURL *fileURL);
@property(nonatomic, copy, nullable) void (^onError)(NSString *message);
- (void)prepare;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
