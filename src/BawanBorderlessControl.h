#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BawanBorderlessButton : NSButton
// Nil keeps the native button's focus mask.
- (nullable NSBezierPath *)bawanFocusRingPath;
@end

NS_ASSUME_NONNULL_END

// NSPopUpButton must keep its native superclass; share these overrides without
// replacing its menu, keyboard handling or accessibility behavior.
#define BAWAN_BORDERLESS_CONTROL_METHODS(FocusPath) \
- (NSRect)alignmentRectForFrame:(NSRect)frame { return frame; } \
- (NSRect)frameForAlignmentRect:(NSRect)rect { return rect; } \
- (NSRect)focusRingMaskBounds { \
    NSBezierPath *path = (FocusPath); \
    return path ? path.bounds : [super focusRingMaskBounds]; \
} \
- (void)drawFocusRingMask { \
    NSBezierPath *path = (FocusPath); \
    if (path) [path fill]; \
    else [super drawFocusRingMask]; \
} \
- (void)viewDidChangeEffectiveAppearance { \
    [super viewDidChangeEffectiveAppearance]; \
    self.needsDisplay = YES; \
}
