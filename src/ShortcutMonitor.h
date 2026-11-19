#import <Foundation/Foundation.h>
#import "ShortcutPreferences.h"
#import "SelectionResult.h"

@class NSTextView;

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
@property(nonatomic, copy, nullable) void (^onOpenPanel)(void);
@property(nonatomic, copy, nullable) void (^onAvailabilityChanged)(void);
@property(nonatomic, copy, nullable) void (^onSelection)(SelectionResult *result);
@property(nonatomic) BOOL suspended;
@property(nonatomic) BOOL configurationActive;
// While configuring, only this focused selection may exercise Translate Selection.
@property(nonatomic, weak, nullable) NSTextView *selectionTrialView;
- (instancetype)initWithPreferences:(ShortcutPreferences *)preferences;
- (void)start;
- (void)stop;
- (void)refresh;
- (ShortcutAvailability)availabilityForAction:(bawan::ShortcutAction)action;
- (void)requestPermissionForAction:(bawan::ShortcutAction)action;
@end

NS_ASSUME_NONNULL_END
