#import <AppKit/AppKit.h>
#import "BawanAppearance.h"

@class BawanMascotView;

NS_ASSUME_NONNULL_BEGIN

// Window chrome shared by the translator, onboarding and Settings so every
// page in the one Bawan window has the same surface, masthead and footer.

static constexpr CGFloat BawanChromeInset = 24;
static constexpr CGFloat BawanFooterHeight = 72;
static constexpr CGFloat BawanFooterButtonHeight = 40;
static constexpr CGFloat BawanFooterPrimaryWidth = 184;
static constexpr CGFloat BawanFooterSecondaryWidth = 176;
static constexpr CGFloat BawanChromeLineWidth = 1.5;

@interface BawanSurfaceView : NSView
@property(nonatomic, strong, nullable) NSColor *fillColor;
@property(nonatomic, strong, nullable) NSColor *borderColor;
@property(nonatomic) CGFloat cornerRadius;
@property(nonatomic) BOOL textured;
@property(nonatomic) BOOL masthead;
// Lets a page surface hold key focus without drawing a focus ring.
@property(nonatomic) BOOL acceptsKeyFocus;
@end

@interface BawanActionButton : NSButton
@property(nonatomic) BOOL primary;
@property(nonatomic) BOOL gold;
@property(nonatomic) BOOL plain;
@property(nonatomic) BOOL pressFeedback;
- (void)resetPressFeedback;
@end

struct BawanChromeHeader {
    BawanSurfaceView *header;
    BawanMascotView *mascot;
};

struct BawanChromeFooter {
    BawanSurfaceView *footer;
    BawanSurfaceView *divider;
};

// The rounded, bordered paper surface that fills the window.
BawanSurfaceView *BawanMakeWindowSurface(NSString *identifier, NSRect frame);
BawanSurfaceView *BawanAddSurface(NSView *parent, NSString *identifier, BawanColorRole role);
BawanActionButton *BawanAddActionButton(NSView *_Nullable parent, NSString *identifier, NSString *title,
                                        id _Nullable target, SEL _Nullable action, BOOL primary);

// The masthead with the centered medallion, pinned to the top of root.
BawanChromeHeader BawanAddHeader(NSView *root, NSString *identifier, NSString *mascotIdentifier);
// The single icon button in the masthead's trailing slot.
BawanActionButton *BawanAddHeaderButton(NSView *header, NSString *identifier, NSString *symbol,
                                        NSString *label, id target, SEL action);

// The footer and its divider, pinned to the bottom of root. Place page content above divider.
BawanChromeFooter BawanAddFooter(NSView *root, NSString *identifier);
BawanActionButton *BawanAddFooterPrimary(NSView *footer, NSString *identifier, NSString *title, id target, SEL action);
BawanActionButton *BawanAddFooterSecondary(NSView *footer, NSString *identifier, NSString *title, id target, SEL action);
// A centered note between the footer's buttons. Pass nil for a missing button.
NSTextField *BawanAddFooterHint(NSView *footer, NSString *identifier, NSString *text,
                                NSView *_Nullable leading, NSView *_Nullable trailing);

NS_ASSUME_NONNULL_END
