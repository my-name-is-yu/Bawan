#import "SetupUI.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <stdexcept>

static void Require(BOOL condition, NSString *message) {
    if (!condition) throw std::runtime_error(message.UTF8String);
}

static BOOL reduceMotion;
static BOOL TestReduceMotion(id, SEL) { return reduceMotion; }

static void SetReduceMotion(BOOL value) {
    reduceMotion = value;
    [NSWorkspace.sharedWorkspace.notificationCenter
        postNotificationName:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
        object:NSWorkspace.sharedWorkspace];
}

static void ServiceAppKit(NSTimeInterval duration, NSRunLoopMode mode = NSDefaultRunLoopMode) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:duration];
    do {
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
            untilDate:[NSDate dateWithTimeIntervalSinceNow:0.005] inMode:mode dequeue:YES];
        if (event) [NSApp sendEvent:event];
        [NSApp updateWindows];
        [CATransaction flush];
    } while (deadline.timeIntervalSinceNow > 0);
}

static NSUInteger AnimationCount(CALayer *layer) {
    NSUInteger count = layer.animationKeys.count;
    if (layer.mask) count += AnimationCount(layer.mask);
    for (CALayer *child in layer.sublayers) count += AnimationCount(child);
    return count;
}

static void RequireStopped(BawanProgressBar *bar, NSString *stage) {
    ServiceAppKit(0.03);
    Require(AnimationCount(bar.layer) == 0,
        [@"No progress animation may remain " stringByAppendingString:stage]);
}

static NSBitmapImageRep *Capture(BawanProgressBar *bar) {
    [bar.window.contentView layoutSubtreeIfNeeded];
    [bar displayIfNeeded];
    [CATransaction flush];
    CALayer *presentation = bar.layer.presentationLayer;
    Require(presentation != nil, @"A shown progress bar must have a presentation layer");
    constexpr CGFloat scale = 4;
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr
        pixelsWide:std::lround(NSWidth(bar.bounds) * scale)
        pixelsHigh:std::lround(NSHeight(bar.bounds) * scale)
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    Require(bitmap != nil, @"Cannot allocate progress presentation capture");
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    CGContextScaleCTM(context.CGContext, scale, scale);
    [presentation renderInContext:context.CGContext];
    return bitmap;
}

static BOOL Matches(NSColor *actual, unsigned rgb) {
    actual = [actual colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return actual.alphaComponent > 0.95 &&
        std::abs(actual.redComponent - ((rgb >> 16) & 255) / 255.0) < 0.04 &&
        std::abs(actual.greenComponent - ((rgb >> 8) & 255) / 255.0) < 0.04 &&
        std::abs(actual.blueComponent - (rgb & 255) / 255.0) < 0.04;
}

struct FillSpan { CGFloat left, right; };

static FillSpan VisibleFill(NSBitmapImageRep *bitmap) {
    NSInteger left = bitmap.pixelsWide, right = -1;
    for (NSInteger x = 0; x < bitmap.pixelsWide; ++x) {
        if (Matches([bitmap colorAtX:x y:bitmap.pixelsHigh / 2], 0xB53B28)) {
            left = std::min(left, x);
            right = x;
        }
    }
    return {left / 4.0, (right + 1) / 4.0};
}

static void RequireMoving(BawanProgressBar *bar, NSString *stage,
                          NSRunLoopMode mode = NSDefaultRunLoopMode) {
    CGFloat minimum = CGFLOAT_MAX, maximum = -CGFLOAT_MAX;
    NSUInteger visibleSamples = 0;
    for (NSUInteger sample = 0; sample < 4; ++sample) {
        ServiceAppKit(0.08, mode);
        FillSpan fill = VisibleFill(Capture(bar));
        if (fill.right <= fill.left) continue;
        CGFloat center = (fill.left + fill.right) / 2;
        minimum = std::min(minimum, center);
        maximum = std::max(maximum, center);
        ++visibleSamples;
    }
    Require(visibleSamples >= 3 && maximum - minimum > 4,
        [@"The visible progress segment must move " stringByAppendingString:stage]);
}

static void RequireStaticSegment(BawanProgressBar *bar, NSString *stage) {
    RequireStopped(bar, stage);
    FillSpan first = VisibleFill(Capture(bar));
    ServiceAppKit(0.15);
    FillSpan second = VisibleFill(Capture(bar));
    Require(std::abs(first.left - second.left) <= 0.25 &&
        std::abs(first.right - second.right) <= 0.25 &&
        std::abs((first.left + first.right) / 2 - NSWidth(bar.bounds) / 2) < 0.5 &&
        std::abs(first.right - first.left - (NSWidth(bar.bounds) - 1.5) * 0.3) < 1,
        [@"Unknown progress must stay visible and centered " stringByAppendingString:stage]);
}

static void CheckDeterminate(BawanProgressBar *bar, NSWindow *window) {
    bar.indeterminate = NO;
    bar.minValue = 0;
    bar.maxValue = 1;
    for (NSAppearanceName name in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
        window.appearance = [NSAppearance appearanceNamed:name];
        BOOL dark = [name isEqualToString:NSAppearanceNameDarkAqua];
        for (NSNumber *value in @[@0, @0.5, @1]) {
            bar.doubleValue = value.doubleValue;
            bar.needsDisplay = YES;
            [window displayIfNeeded];
            ServiceAppKit(0.03);
            RequireStopped(bar, @"for determinate progress");
            NSBitmapImageRep *bitmap = Capture(bar);
            FillSpan fill = VisibleFill(bitmap);
            if (value.doubleValue == 0) {
                Require(fill.right <= fill.left, @"Zero progress must have no accent fill");
            } else {
                Require(std::abs(fill.right - NSWidth(bar.bounds) * value.doubleValue) < 2 && fill.left < 2,
                    @"Determinate fill must retain its zero-to-full proportion");
            }
            if (value.doubleValue < 1) {
                Require(Matches([bitmap colorAtX:bitmap.pixelsWide * 3 / 4 y:bitmap.pixelsHigh / 2],
                    dark ? 0x28211C : 0xF7E7BB), @"Progress track must retain its appearance color");
            }
            Require(Matches([bitmap colorAtX:bitmap.pixelsWide / 2 y:2],
                dark ? 0xA88150 : 0x624530), @"Progress must retain its 1.5pt border at the 0.75pt inset");
            Require(NSEqualSizes(bar.frame.size, NSMakeSize(240, 8)),
                @"Progress rendering must preserve its frame dimensions");
        }
    }
}

static NSWindow *MakeWindow(CGFloat x) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(x, 100, 280, 100)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    return window;
}

static void RunSmoke(void) {
    Method getter = class_getInstanceMethod(NSWorkspace.class, @selector(accessibilityDisplayShouldReduceMotion));
    Require(getter != nullptr, @"Cannot isolate Reduce Motion for the smoke process");
    IMP original = method_setImplementation(getter, reinterpret_cast<IMP>(TestReduceMotion));
    NSWindow *window = MakeWindow(100);
    NSWindow *other = MakeWindow(420);
    @try {
        BawanProgressBar *bar = [[BawanProgressBar alloc] initWithFrame:NSMakeRect(20, 45, 240, 8)];
        bar.style = NSProgressIndicatorStyleBar;
        bar.indeterminate = YES;
        NSView *parent = [[NSView alloc] initWithFrame:window.contentView.bounds];
        NSView *hiddenParent = [[NSView alloc] initWithFrame:window.contentView.bounds];
        hiddenParent.hidden = YES;
        [window.contentView addSubview:parent];
        [window.contentView addSubview:hiddenParent];
        [parent addSubview:bar];
        [bar startAnimation:nil];
        RequireStopped(bar, @"before its window is shown");
        [window makeKeyAndOrderFront:nil];
        RequireMoving(bar, @"after showing its window");
        RequireMoving(bar, @"during event tracking", NSEventTrackingRunLoopMode);

        SetReduceMotion(YES);
        RequireStaticSegment(bar, @"after enabling Reduce Motion during playback");
        SetReduceMotion(NO);
        RequireMoving(bar, @"after disabling Reduce Motion");

        bar.hidden = YES;
        RequireStopped(bar, @"while hidden");
        bar.hidden = NO;
        RequireMoving(bar, @"after unhiding");
        parent.hidden = YES;
        RequireStopped(bar, @"while its ancestor is hidden");
        parent.hidden = NO;
        RequireMoving(bar, @"after unhiding its ancestor");
        [hiddenParent addSubview:bar];
        RequireStopped(bar, @"after moving under a hidden ancestor");
        [parent addSubview:bar];
        RequireMoving(bar, @"after moving back to a shown ancestor");

        [bar removeFromSuperview];
        RequireStopped(bar, @"after detaching from its window");
        [other.contentView addSubview:bar];
        RequireStopped(bar, @"after attaching to an unshown window");
        [other makeKeyAndOrderFront:nil];
        RequireMoving(bar, @"after showing its new window");
        [parent addSubview:bar];
        [other close];
        RequireMoving(bar, @"after its previous window closes");

        [window orderOut:nil];
        RequireStopped(bar, @"after ordering its window out");
        [window makeKeyAndOrderFront:nil];
        RequireMoving(bar, @"after ordering its window in");
        [window close];
        RequireStopped(bar, @"after closing its window");
        [window makeKeyAndOrderFront:nil];
        RequireMoving(bar, @"after reopening its window");

        CheckDeterminate(bar, window);
        bar.indeterminate = YES;
        RequireMoving(bar, @"after returning to indeterminate progress");
        [bar stopAnimation:nil];
        bar.indeterminate = NO;
        bar.indeterminate = YES;
        bar.hidden = YES;
        bar.hidden = NO;
        SetReduceMotion(YES);
        SetReduceMotion(NO);
        RequireStaticSegment(bar, @"after an explicit stop and visibility/preferences changes");
        [bar startAnimation:nil];
        RequireMoving(bar, @"after an explicit restart");
        SetReduceMotion(YES);
        bar.frame = NSMakeRect(20, 45, 200, 8);
        [bar layoutSubtreeIfNeeded];
        RequireStaticSegment(bar, @"after resizing with Reduce Motion");
        SetReduceMotion(NO);
        RequireMoving(bar, @"after resuming at the new size");
        std::cout << "progress_smoke_complete=true\ntracking_motion=true\nlifecycle_restart=true\n"
                     "live_reduce_motion=true\ndeterminate_appearance=true\n";
    } @finally {
        [window close];
        [other close];
        method_setImplementation(getter, original);
    }
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        __block int result = EXIT_FAILURE;
        [NSRunLoop.mainRunLoop performBlock:^{
            @try {
                try { RunSmoke(); result = EXIT_SUCCESS; }
                catch (const std::exception &error) { std::cerr << "Progress smoke failed: " << error.what() << '\n'; }
            } @catch (NSException *exception) {
                std::cerr << "Progress smoke failed: " << exception.reason.UTF8String << '\n';
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
