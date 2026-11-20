#import <AppKit/AppKit.h>
#import "LaunchMode.h"

@interface AppDelegate : NSObject <NSApplicationDelegate>
- (instancetype)initWithLaunchMode:(bawan::LaunchMode)mode;
@end
