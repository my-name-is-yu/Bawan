#import <AppKit/AppKit.h>
#import "BawanAppearance.h"
#import "BawanBorderlessControl.h"

@class BawanActionButton;

NS_ASSUME_NONNULL_BEGIN

// One type scale for the setup pages, all in the translator's serif.
static constexpr CGFloat BawanSetupTitleSize = 24;    // Page title.
static constexpr CGFloat BawanSetupSectionSize = 18;  // Section heading.
static constexpr CGFloat BawanSetupRowTitleSize = 15; // Row and control titles.
static constexpr CGFloat BawanSetupBodySize = 14;     // Explanations.
static constexpr CGFloat BawanSetupCaptionSize = 13;  // Statuses and small buttons.
static constexpr CGFloat BawanSetupButtonHeight = 32;
static constexpr CGFloat BawanSetupRowHeight = 56;
static constexpr CGFloat BawanSetupKeyWidth = 128;    // Shortcut key, recorder or read-only.
static constexpr CGFloat BawanSetupCountWidth = 80;   // Press count, popup or read-only.
static constexpr CGFloat BawanSetupActionWidth = 84;  // Shortcut permission action.
static constexpr CGFloat BawanSetupModelActionWidth = 224; // Model setup or retry.

// A flipped, transparent document so scrolled setup content starts at the top.
@interface BawanSetupDocument : NSView
@end

// A read-only value drawn on the same input surface as the shortcut recorder.
@interface BawanSetupKeycap : NSTextField
@end

// Checkbox, switch and progress bar drawn in Bawan's palette instead of the
// system accent, keeping the native control semantics and accessibility.
@interface BawanCheckbox : BawanBorderlessButton
@end

@interface BawanToggle : BawanBorderlessButton
@end

@interface BawanProgressBar : NSProgressIndicator
@end

// Shows a page from the top with its ring-less surface focused: Esc and ⌘Return
// still work and Tab moves into the controls, but no control shows a focus ring
// until the user navigates with the keyboard.
void BawanSetupPresentPage(NSView *page, NSScrollView *scroll);
NSTextField *BawanSetupHeading(NSString *text, CGFloat size);
NSStackView *BawanSetupStack(NSArray<NSView *> *views, NSUserInterfaceLayoutOrientation orientation, CGFloat spacing);
NSView *BawanSetupRule(void);
// A small beveled secondary button for in-page actions.
BawanActionButton *BawanSetupButton(NSString *identifier, NSString *title, CGFloat width, id target, SEL action);
// The shared row: title over status on the leading side, controls on the trailing side.
NSView *BawanSetupRow(NSString *identifier, NSView *title, NSView *status, NSArray<NSView *> *controls);
// The same row, inset from the content edges (the onboarding list layout).
NSView *BawanSetupInsetRow(NSString *identifier, NSView *title, NSView *status, NSArray<NSView *> *controls,
                           CGFloat leadingInset, CGFloat trailingInset);

NS_ASSUME_NONNULL_END
