#import <Foundation/Foundation.h>
#import "ShortcutPreferences.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ShortcutAvailability) {
    ShortcutAvailabilityOff,
    ShortcutAvailabilityAvailable,
    ShortcutAvailabilityNeedsInputMonitoring,
    ShortcutAvailabilityNeedsAccessibility,
    ShortcutAvailabilityFailed
};

// Main-thread callbacks. Only the default copy gesture is a passive listener.
@interface ShortcutMonitor : NSObject
@property(nonatomic, copy, nullable) void (^onText)(NSString *text);
@property(nonatomic, copy, nullable) void (^onProblem)(NSString *message);
@property(nonatomic, copy, nullable) void (^onOpenPanel)(void);
@property(nonatomic, copy, nullable) void (^onStateChanged)(void);
@property(nonatomic) BOOL suspended;
@property(nonatomic) BOOL configurationActive;
- (instancetype)initWithPreferences:(ShortcutPreferences *)preferences;
- (void)start;
- (void)stop;
// Applies bindings and availability before notifying. Unchanged refreshes are silent.
- (void)refresh;
// Batch one UI operation, including recorder state and permission checks. The
// outermost update publishes once after the block finishes, even if unchanged.
- (void)updateConfiguration:(void (^)(void))update;
- (ShortcutAvailability)availabilityForAction:(bawan::ShortcutAction)action;
- (void)requestPermissionForAction:(bawan::ShortcutAction)action;
@end

NS_ASSUME_NONNULL_END
