#import "LoreAppearance.h"
#import "LoreMascotView.h"
#import <QuartzCore/QuartzCore.h>

#include <cstdlib>
#include <iostream>
#include <stdexcept>

static void Require(BOOL condition, NSString *message) {
    if (!condition) throw std::runtime_error(message.UTF8String);
}

static CALayer *NamedLayer(CALayer *root, NSString *name) {
    if ([root.name isEqualToString:name]) return root;
    for (CALayer *child in root.sublayers) {
        if (CALayer *found = NamedLayer(child, name)) return found;
    }
    return nil;
}

static NSUInteger AnimationCount(CALayer *root) {
    NSUInteger result = root.animationKeys.count;
    if (root.mask) result += AnimationCount(root.mask);
    for (CALayer *child in root.sublayers) result += AnimationCount(child);
    return result;
}

static NSString *TransformDescription(CATransform3D transform) {
    return [NSString stringWithFormat:@"m11=%.4f m12=%.4f m21=%.4f m22=%.4f tx=%.4f ty=%.4f",
        transform.m11, transform.m12, transform.m21, transform.m22, transform.m41, transform.m42];
}

static void DumpAnimations(CALayer *layer) {
    NSArray<NSString *> *keys = layer.animationKeys;
    if (layer.name || keys.count > 0) {
        CALayer *presentation = layer.presentationLayer;
        NSString *diagnostic = [NSString stringWithFormat:
            @"layer=%@ keys=%@ localTime=%.4f model={%@} presentation={%@}",
            layer.name ?: NSStringFromClass(layer.class), keys ?: @[],
            [layer convertTime:CACurrentMediaTime() fromLayer:nil], TransformDescription(layer.transform),
            presentation ? TransformDescription(presentation.transform) : @"unavailable"];
        std::cerr << diagnostic.UTF8String << '\n';
        for (NSString *key in keys) {
            CAAnimation *animation = [layer animationForKey:key];
            NSString *detail = [NSString stringWithFormat:
                @"  key=%@ beginTime=%.4f duration=%.4f speed=%.4f timeOffset=%.4f repeatCount=%.4f removedOnCompletion=%@",
                key, animation.beginTime, animation.duration, animation.speed, animation.timeOffset,
                animation.repeatCount, animation.removedOnCompletion ? @"yes" : @"no"];
            std::cerr << detail.UTF8String << '\n';
        }
    }
    if (layer.mask) DumpAnimations(layer.mask);
    for (CALayer *child in layer.sublayers) DumpAnimations(child);
}

static void ServiceAppKit(NSTimeInterval duration) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:duration];
    do {
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
            untilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]
            inMode:NSDefaultRunLoopMode dequeue:YES];
        if (event) [NSApp sendEvent:event];
        [NSApp updateWindows];
    } while (deadline.timeIntervalSinceNow > 0);
}

static void RequireReset(LoreMascotView *view, NSString *stage) {
    if (AnimationCount(view.layer) > 0) {
        std::cerr << "Unremoved hover animation " << stage.UTF8String << '\n';
        DumpAnimations(view.layer);
    }
    Require(AnimationCount(view.layer) == 0,
        [@"Hover animations must be removed " stringByAppendingString:stage]);
    for (NSString *name in @[@"lore.mascot.dog", @"lore.mascot.left-ear", @"lore.mascot.right-ear"]) {
        CALayer *layer = NamedLayer(view.layer, name);
        Require(layer != nil && CATransform3DIsIdentity(layer.transform),
            [NSString stringWithFormat:@"%@ must return to its resting transform %@", name, stage]);
    }
    for (NSString *name in @[@"lore.mascot.left-lid", @"lore.mascot.right-lid"]) {
        CALayer *layer = NamedLayer(view.layer, name);
        Require(layer != nil && layer.opacity == 0,
            [NSString stringWithFormat:@"%@ must return to open eyes %@", name, stage]);
    }
}

static void RequireFinite(CALayer *layer) {
    NSArray<NSString *> *keys = layer.animationKeys;
    Require(keys.count == 1 && [keys.firstObject isEqualToString:@"lore.hover"],
        [NSString stringWithFormat:@"%@ must own one replaceable hover animation", layer.name]);
    CAAnimation *animation = [layer animationForKey:@"lore.hover"];
    Require(animation.duration > 0 && animation.duration <= 0.28 + 0.0001 &&
        animation.repeatCount == 0 && animation.repeatDuration == 0 && !animation.autoreverses &&
        animation.removedOnCompletion,
        [NSString stringWithFormat:@"%@ must use one finite, automatically removed animation", layer.name]);
}

static void CapturePresentation(LoreMascotView *view, NSString *motion) {
    // These are compositor-layer samples, not an AppKit cacheDisplay snapshot of
    // the resting model. The owning test window stays the same for every preset.
    CALayer *presentation = view.layer.presentationLayer;
    if (!presentation) return;
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr
        pixelsWide:288 pixelsHigh:288 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
        isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    Require(bitmap != nil, @"Cannot allocate mascot capture");
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    if (view.isFlipped) {
        CGContextTranslateCTM(context.CGContext, 0, 288);
        CGContextScaleCTM(context.CGContext, 288.0 / view.bounds.size.width,
            -288.0 / view.bounds.size.height);
    } else {
        CGContextScaleCTM(context.CGContext, 288.0 / view.bounds.size.width,
            288.0 / view.bounds.size.height);
    }
    [presentation renderInContext:context.CGContext];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *path = [@"mascot-smoke" stringByAppendingPathComponent:[motion stringByAppendingString:@".png"]];
    Require([png writeToFile:path atomically:YES], @"Cannot save mascot presentation capture");
}

static void RunSmoke(void) {
    Require([NSFileManager.defaultManager createDirectoryAtPath:@"mascot-smoke"
        withIntermediateDirectories:YES attributes:nil error:nil], @"Cannot create mascot capture directory");
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 184, 96)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    LoreMascotView *first = [[LoreMascotView alloc] initWithFrame:NSMakeRect(8, 8, LoreBrandMarkSize, LoreBrandMarkSize)];
    LoreMascotView *second = [[LoreMascotView alloc] initWithFrame:NSMakeRect(100, 8, LoreBrandMarkSize, LoreBrandMarkSize)];
    [window.contentView addSubview:first];
    [window.contentView addSubview:second];
    [window makeKeyAndOrderFront:nil];
    [window.contentView layoutSubtreeIfNeeded];
    [window displayIfNeeded];
    [CATransaction flush];
    ServiceAppKit(0.02);
    NSPoint hoverPoint = [first convertPoint:NSMakePoint(NSMidX(first.bounds), NSMidY(first.bounds)) toView:nil];
    NSTimeInterval timestamp = NSProcessInfo.processInfo.systemUptime;
    NSEvent *entered = [NSEvent enterExitEventWithType:NSEventTypeMouseEntered location:hoverPoint
        modifierFlags:0 timestamp:timestamp windowNumber:window.windowNumber context:nil
        eventNumber:1 trackingNumber:0 userData:nullptr];
    NSEvent *exited = [NSEvent enterExitEventWithType:NSEventTypeMouseExited location:hoverPoint
        modifierFlags:0 timestamp:timestamp windowNumber:window.windowNumber context:nil
        eventNumber:2 trackingNumber:0 userData:nullptr];
    NSEvent *clicked = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:hoverPoint
        modifierFlags:0 timestamp:timestamp windowNumber:window.windowNumber context:nil
        eventNumber:3 clickCount:1 pressure:1];
    NSEvent *clickedAgain = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:hoverPoint
        modifierFlags:0 timestamp:timestamp + 0.01 windowNumber:window.windowNumber context:nil
        eventNumber:4 clickCount:2 pressure:1];
    Require(entered != nil && exited != nil && clicked != nil && clickedAgain != nil,
        @"Cannot create native hover and click events");
    Require([first acceptsFirstMouse:clicked] && ![first mouseDownCanMoveWindow],
        @"A mascot click must work in an inactive window without dragging it");

    Require(first.image != nil && first.image == second.image && first.image == LoreMascotImage(),
        @"Both mascot views must share the cached display-sized image");
    CALayer *face = NamedLayer(first.layer, @"lore.mascot.face");
    CALayer *otherFace = NamedLayer(second.layer, @"lore.mascot.face");
    Require(face != nil && face.contents != nil && face.contents == otherFace.contents,
        @"Both mascot faces must share decoded image contents");
    CFTypeRef contents = (__bridge CFTypeRef)face.contents;
    Require(CFGetTypeID(contents) == CGImageGetTypeID(), @"Mascot layers must use decoded CGImage contents");
    CGImageRef image = (CGImageRef)contents;
    Require(CGImageGetWidth(image) <= 144 && CGImageGetHeight(image) <= 144 &&
        CGImageGetBitsPerPixel(image) <= 32,
        @"The shared mascot must be decoded at display size, not at the original source resolution");
    size_t pixelBytes = CGImageGetBytesPerRow(image) * CGImageGetHeight(image);
    Require(pixelBytes <= 144 * 144 * 4 + 144 * 64,
        @"The decoded mascot payload must remain bounded, allowing native row padding");
    id sharedContents = face.contents;
    NSRect fixedFrame = first.frame;
    CGRect fixedBounds = first.layer.bounds;
    CGPoint fixedPosition = first.layer.position;
    RequireReset(first, @"before hovering");

    BOOL reducedMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    if (reducedMotion) {
        [first mouseEntered:entered];
        RequireReset(first, @"with OS Reduce Motion enabled");
        [first mouseDown:clicked];
        RequireReset(first, @"after clicking with OS Reduce Motion enabled");
        [first mouseExited:exited];
    } else {
        NSMutableSet<NSString *> *motions = [NSMutableSet set];
        // Exercise the three distinct hover choices once each, without repeated
        // window opening or a lifecycle stress loop.
        for (NSUInteger choice = 0; choice < 3; ++choice) {
            [first mouseEntered:entered];
            CALayer *dog = NamedLayer(first.layer, @"lore.mascot.dog");
            RequireFinite(dog);
            NSString *motion = [[dog animationForKey:@"lore.hover"] valueForKey:@"lore.motion"];
            Require([motion isKindOfClass:NSString.class] && motion.length > 0,
                @"Each hover must identify the motion selected for this playback");
            [motions addObject:motion];
            for (NSString *name in @[@"lore.mascot.left-ear", @"lore.mascot.right-ear",
                @"lore.mascot.left-lid", @"lore.mascot.right-lid"]) {
                CALayer *part = NamedLayer(first.layer, name);
                Require(part != nil, [@"Missing expressive mascot part: " stringByAppendingString:name]);
                RequireFinite(part);
            }
            Require(first.layer.animationKeys.count == 0 &&
                CATransform3DIsIdentity(first.layer.transform) && NSEqualRects(first.frame, fixedFrame) &&
                CGRectEqualToRect(first.layer.bounds, fixedBounds) &&
                CGPointEqualToPoint(first.layer.position, fixedPosition),
                @"Hovering must leave the round medallion, its frame and hit area fixed");
            [first mouseEntered:entered];
            Require([[[dog animationForKey:@"lore.hover"] valueForKey:@"lore.motion"] isEqual:motion],
                @"A duplicate entry while already inside must not start another preset");
            RequireFinite(dog);
            [window displayIfNeeded];
            [CATransaction flush];
            ServiceAppKit(0.12);
            CapturePresentation(first, motion);
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.5];
            while (AnimationCount(first.layer) > 0 && deadline.timeIntervalSinceNow > 0) ServiceAppKit(0.01);
            RequireReset(first, @"after a hover finishes");
            Require(NamedLayer(first.layer, @"lore.mascot.face").contents == sharedContents,
                @"Playback must reuse the decoded image");
            [first mouseExited:exited];
        }
        Require([motions isEqualToSet:[NSSet setWithArray:@[@"tilt", @"hop", @"shake"]]],
            @"The three entries must exercise tilt, hop and shake");

        [first mouseEntered:entered];
        [window displayIfNeeded];
        [CATransaction flush];
        ServiceAppKit(0.05);
        [first mouseExited:exited];
        [first mouseEntered:entered];
        CALayer *replacementDog = NamedLayer(first.layer, @"lore.mascot.dog");
        NSString *replacementMotion = [[replacementDog animationForKey:@"lore.hover"] valueForKey:@"lore.motion"];
        RequireFinite(replacementDog);
        [window displayIfNeeded];
        [CATransaction flush];
        // Drain the canceled playback's completion with ample time left on
        // the replacement, rather than sampling near its natural end.
        ServiceAppKit(0.03);
        Require([[[replacementDog animationForKey:@"lore.hover"] valueForKey:@"lore.motion"]
                    isEqual:replacementMotion],
            @"An interrupted hover's completion must not remove its replacement playback");
        RequireFinite(replacementDog);
        NSDate *replacementDeadline = [NSDate dateWithTimeIntervalSinceNow:0.5];
        while (AnimationCount(first.layer) > 0 && replacementDeadline.timeIntervalSinceNow > 0) ServiceAppKit(0.01);
        RequireReset(first, @"after the replacement hover finishes");
        [first mouseExited:exited];

        [first mouseEntered:entered];
        [window displayIfNeeded];
        [CATransaction flush];
        NSDate *clickReadyDeadline = [NSDate dateWithTimeIntervalSinceNow:0.5];
        while (AnimationCount(first.layer) > 0 && clickReadyDeadline.timeIntervalSinceNow > 0) ServiceAppKit(0.01);
        RequireReset(first, @"after hovering finishes while the pointer stays inside");
        [first mouseDown:clicked];
        RequireFinite(NamedLayer(first.layer, @"lore.mascot.dog"));
        Require(first.image == second.image &&
            NamedLayer(first.layer, @"lore.mascot.face").contents == sharedContents &&
            NSEqualRects(first.frame, fixedFrame) && CGRectEqualToRect(first.layer.bounds, fixedBounds) &&
            CGPointEqualToPoint(first.layer.position, fixedPosition) && first.layer.animationKeys.count == 0,
            @"Clicking from inside must reuse the image and keep the medallion fixed");
        [first mouseExited:exited];
        RequireReset(first, @"after leaving during click playback");

        [first mouseEntered:entered];
        CALayer *clickedDog = NamedLayer(first.layer, @"lore.mascot.dog");
        NSString *hoverMotion = [[clickedDog animationForKey:@"lore.hover"] valueForKey:@"lore.motion"];
        [first mouseDown:clickedAgain];
        NSString *clickMotion = [[clickedDog animationForKey:@"lore.hover"] valueForKey:@"lore.motion"];
        Require(clickMotion != nil && ![clickMotion isEqual:hoverMotion],
            @"Clicking during a running hover must replace it with the next preset");
        for (NSString *name in @[@"lore.mascot.dog", @"lore.mascot.left-ear", @"lore.mascot.right-ear",
            @"lore.mascot.left-lid", @"lore.mascot.right-lid"]) {
            RequireFinite(NamedLayer(first.layer, name));
        }
        Require(NamedLayer(first.layer, @"lore.mascot.face").contents == sharedContents &&
            NSEqualRects(first.frame, fixedFrame) && first.layer.animationKeys.count == 0,
            @"Replacing hover playback with a click must not duplicate images or move the medallion");
        [first mouseExited:exited];
        RequireReset(first, @"after leaving during a replacement click");

        [first mouseEntered:entered];
        [first mouseExited:exited];
        RequireReset(first, @"after leaving during playback");
        [first mouseEntered:entered];
        [first resetHoverAnimation];
        RequireReset(first, @"after the owner cancels playback");
        [first mouseEntered:entered];
        [first removeFromSuperview];
        RequireReset(first, @"after detaching the view");
    }
    [window close];
    std::cout << "mascot_smoke_complete=true\nshared_decoded_pixel_bytes=" << pixelBytes
        << "\nreduce_motion_enabled=" << static_cast<bool>(reducedMotion)
        << "\nfixed_medallion=true\ncaptures=mascot-smoke\n";
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        __block int result = EXIT_FAILURE;
        [NSRunLoop.mainRunLoop performBlock:^{
            @try {
                try { RunSmoke(); result = EXIT_SUCCESS; }
                catch (const std::exception &error) { std::cerr << "Mascot smoke failed: " << error.what() << '\n'; }
            } @catch (NSException *exception) {
                std::cerr << "Mascot smoke failed: " << exception.reason.UTF8String << '\n';
            }
            [NSApp stop:nil];
            [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
                location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];
        }];
        [NSApp run];
        return result;
    }
}
