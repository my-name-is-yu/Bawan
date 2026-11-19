#pragma once

#import <AppKit/AppKit.h>
#import <QuartzCore/CALayer.h>

#include <cmath>
#include <stdexcept>

namespace ControlAppearanceChecks {
inline void Require(BOOL condition, NSView *view, NSString *message) {
    if (!condition) throw std::runtime_error(
        [NSString stringWithFormat:@"%@: %@", view.identifier, message].UTF8String);
}

// Draw on transparency so a disabled face's alpha is independent of its parent.
inline NSBitmapImageRep *Render(NSView *view, BOOL focusMask = NO) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil
        pixelsWide:static_cast<NSInteger>(std::ceil(NSWidth(view.bounds)))
        pixelsHigh:static_cast<NSInteger>(std::ceil(NSHeight(view.bounds)))
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    bitmap = [bitmap bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.sRGBColorSpace];
    Require(bitmap != nil, view, @"Could not allocate a control capture");
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    Require(context != nil, view, @"Could not create a control capture context");
    CGContextRef cg = context.CGContext;
    if (view.isFlipped) {
        CGContextTranslateCTM(cg, 0, NSHeight(view.bounds));
        CGContextScaleCTM(cg, 1, -1);
    }
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:
        [NSGraphicsContext graphicsContextWithCGContext:cg flipped:view.isFlipped]];
    [view.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [NSColor.clearColor setFill];
        NSRectFillUsingOperation(view.bounds, NSCompositingOperationCopy);
        if (focusMask) {
            [NSColor.blackColor setFill];
            [view drawFocusRingMask];
        } else {
            [view drawRect:view.bounds];
        }
    }];
    [NSGraphicsContext restoreGraphicsState];
    return bitmap;
}

inline NSColor *Pixel(NSBitmapImageRep *bitmap, NSPoint point) {
    return [bitmap colorAtX:static_cast<NSInteger>(point.x) y:static_cast<NSInteger>(point.y)];
}

inline void Check(NSButton *control, NSPoint facePoint, BOOL changesWithAppearance, NSString *directory) {
    NSRect frame = NSMakeRect(17, 23, 128, 28);
    Require(NSEqualRects([control alignmentRectForFrame:frame], frame) &&
        NSEqualRects([control frameForAlignmentRect:frame], frame), control,
        @"Native ornament insets must not change the custom control's layout");
    Require(control.focusRingType == NSFocusRingTypeExterior, control,
        @"Keyboard focus must retain its exterior ring");
    NSAppearance *previousAppearance = control.window.appearance;
    BOOL previousEnabled = control.enabled;
    CGFloat lightFace = 0;
    for (NSAppearanceName name in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
        control.window.appearance = [NSAppearance appearanceNamed:name];
        [control displayIfNeeded];
        [control.layer displayIfNeeded];
        control.needsDisplay = NO;
        Require(!control.needsDisplay && !control.layer.needsDisplay, control,
            @"The appearance callback must start without a pending view or layer repaint");
        [control viewDidChangeEffectiveAppearance];
        Require(control.needsDisplay || control.layer.needsDisplay, control,
            @"An appearance change must request a view or layer repaint");
        for (NSNumber *enabled in @[@YES, @NO]) {
            control.enabled = enabled.boolValue;
            NSBitmapImageRep *bitmap = Render(control);
            NSColor *face = Pixel(bitmap, facePoint);
            Require(std::abs(face.alphaComponent - (enabled.boolValue ? 1.0 : 0.4)) < 0.02,
                control, @"Enabled faces must be opaque; disabled faces must use the shared 40% opacity");
            if (enabled.boolValue) {
                if ([name isEqualToString:NSAppearanceNameAqua]) lightFace = face.redComponent;
                else if (changesWithAppearance) Require(lightFace > face.redComponent + 0.3,
                    control, @"The visible input face must change with the light/dark palette");
            }
            NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:
                @"control-%@-%@-%ld-%@.png", control.identifier, name, static_cast<long>(control.state),
                enabled.boolValue ? @"enabled" : @"disabled"]];
            Require([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                writeToFile:path atomically:YES], control, @"Could not save a control capture");
        }
    }
    control.enabled = previousEnabled;
    control.window.appearance = previousAppearance;
}

inline void CheckFocus(NSView *control, NSRect bounds, NSPoint inside, NSPoint corner,
                       NSPoint outside, NSString *directory) {
    Require(NSEqualRects(control.focusRingMaskBounds, bounds), control,
        @"The focus ring must retain its control-specific bounds");
    NSBitmapImageRep *mask = Render(control, YES);
    Require(Pixel(mask, inside).alphaComponent > 0.95 &&
        Pixel(mask, corner).alphaComponent < 0.05 && Pixel(mask, outside).alphaComponent < 0.05,
        control, @"The focus mask must preserve its rounded shape and exclude surrounding content");
    NSString *path = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"focus-%@.png", control.identifier]];
    Require([[mask representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:path atomically:YES], control, @"Could not save a focus-mask capture");
}

inline void CheckNativeFocus(NSButton *control, NSString *directory) {
    NSButton *native = [[NSButton alloc] initWithFrame:control.bounds];
    native.cell = [control.cell copy];
    native.appearance = control.effectiveAppearance;
    native.focusRingType = control.focusRingType;
    Require(NSEqualRects(control.focusRingMaskBounds, native.focusRingMaskBounds), control,
        @"Action buttons must retain native focus-mask bounds");
    NSBitmapImageRep *actual = Render(control, YES);
    NSBitmapImageRep *expected = Render(native, YES);
    for (NSInteger y = 0; y < actual.pixelsHigh; ++y) {
        for (NSInteger x = 0; x < actual.pixelsWide; ++x) {
            Require(std::abs([actual colorAtX:x y:y].alphaComponent -
                [expected colorAtX:x y:y].alphaComponent) < 0.02, control,
                @"Action buttons must retain native focus-mask drawing");
        }
    }
    NSString *path = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"focus-%@.png", control.identifier]];
    Require([[actual representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:path atomically:YES], control, @"Could not save a native focus-mask capture");
}
}
