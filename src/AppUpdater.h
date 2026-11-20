#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppUpdater : NSObject
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) BOOL canCheckForUpdates;
@property(nonatomic, readonly) BOOL installingUpdate;
@property(nonatomic, readonly) BOOL relaunchPostponed;
@property(nonatomic) BOOL automaticallyChecksForUpdates;
@property(nonatomic) BOOL translationBusy;
@property(nonatomic) BOOL translationActive;
@property(nonatomic, copy, nullable) void (^onStateChanged)(void);
- (void)start;
- (void)checkForUpdates:(nullable id)sender;
- (void)resumePostponedRelaunch;
@end

NS_ASSUME_NONNULL_END
