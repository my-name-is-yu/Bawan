#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// All entry points and callbacks run on the main thread. This is a passive
// listener: it neither synthesizes nor suppresses the user's copy events.
@interface ShortcutMonitor : NSObject
@property(nonatomic, copy, nullable) void (^onText)(NSString *text);
@property(nonatomic, copy, nullable) void (^onProblem)(NSString *message);
@property(nonatomic, readonly, getter=isListening) BOOL listening;
- (BOOL)startRequestingPermission:(BOOL)request;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
