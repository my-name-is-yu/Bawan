#import <AppKit/AppKit.h>
#import "BawanAppearance.h"

NS_ASSUME_NONNULL_BEGIN

@interface BawanSetupPaper : NSView
@property(nonatomic) BOOL masthead;
@end

@interface BawanSetupDocument : BawanSetupPaper
@end

@interface BawanSetupGroup : NSBox
@end

@interface BawanSetupActionButton : NSButton
@property(nonatomic) BOOL primary;
@end

@interface BawanSetupKeycap : NSTextField
@end

NSStackView *BawanSetupStack(NSArray<NSView *> *views, NSUserInterfaceLayoutOrientation orientation, CGFloat spacing);
NSButton *BawanSetupLink(NSString *title, id target, SEL action);
NSView *BawanSetupRule(void);

NS_ASSUME_NONNULL_END
