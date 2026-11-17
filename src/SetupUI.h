#import <AppKit/AppKit.h>
#import "BawanAppearance.h"

NS_ASSUME_NONNULL_BEGIN

// A flipped, transparent document so scrolled setup content starts at the top.
@interface BawanSetupDocument : NSView
@end

@interface BawanSetupGroup : NSBox
@end

@interface BawanSetupKeycap : NSTextField
@end

NSStackView *BawanSetupStack(NSArray<NSView *> *views, NSUserInterfaceLayoutOrientation orientation, CGFloat spacing);
NSButton *BawanSetupLink(NSString *title, id target, SEL action);
NSView *BawanSetupRule(void);

NS_ASSUME_NONNULL_END
