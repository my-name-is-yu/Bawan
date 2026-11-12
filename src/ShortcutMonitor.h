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
@property(nonatomic, copy, nullable) void (^onAvailabilityChanged)(void);
@property(nonatomic) BOOL suspended;
@property(nonatomic) BOOL settingsActive;
- (instancetype)initWithPreferences:(ShortcutPreferences *)preferences;
- (void)start;
- (void)stop;
- (void)refresh;
- (ShortcutAvailability)availabilityForAction:(lore::ShortcutAction)action;
- (void)requestPermissionForAction:(lore::ShortcutAction)action;
@end

NS_ASSUME_NONNULL_END
