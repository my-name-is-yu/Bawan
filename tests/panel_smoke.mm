#import "TranslationPanel.h"
#import "LoreAppearance.h"
#import <QuartzCore/QuartzCore.h>

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <stdexcept>

static void Require(BOOL condition, NSString *message) {
    if (!condition) throw std::runtime_error(message.UTF8String);
}

static NSView *FindView(NSView *view, NSString *identifier) {
    if ([view.identifier isEqualToString:identifier]) return view;
    for (NSView *child in view.subviews) {
        if (NSView *found = FindView(child, identifier)) return found;
    }
    return nil;
}

static NSView *Control(NSWindow *window, NSString *identifier, Class type) {
    NSView *view = FindView(window.contentView, identifier);
    Require([view isKindOfClass:type], [@"Missing control: " stringByAppendingString:identifier]);
    return view;
}

static NSWindow *PanelWindow(void) {
    NSWindow *result = nil;
    NSUInteger count = 0;
    for (NSWindow *window in NSApp.windows) {
        if ([window.contentView.identifier isEqualToString:@"lore-panel"]) {
            result = window;
            ++count;
        }
    }
    Require(count == 1, @"Expected exactly one reusable translation panel");
    return result;
}

static void Settle(NSWindow *window) {
    [window.contentView layoutSubtreeIfNeeded];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    [window.contentView layoutSubtreeIfNeeded];
}

// Compare app-owned objects, not private scroller, field-editor or layout-manager caches.
// NSValue stores addresses without keeping old views/constraints alive during the test.
static void CollectObjects(NSView *view, NSMutableSet<NSValue *> *views,
                           NSMutableSet<NSValue *> *constraints) {
    [views addObject:[NSValue valueWithPointer:(__bridge const void *)view]];
    for (NSLayoutConstraint *constraint in view.constraints) {
        if ([constraint.identifier hasPrefix:@"lore."]) {
            [constraints addObject:[NSValue valueWithPointer:(__bridge const void *)constraint]];
        }
    }
    if ([view isKindOfClass:NSScrollView.class]) {
        NSView *document = ((NSScrollView *)view).documentView;
        if (document) CollectObjects(document, views, constraints);
        return;
    }
    if ([view isKindOfClass:NSTextView.class] || [view isKindOfClass:NSControl.class]) return;
    for (NSView *child in view.subviews) CollectObjects(child, views, constraints);
}

static void CheckBounds(NSWindow *window) {
    NSView *root = window.contentView;
    Require(!root.hasAmbiguousLayout, @"Panel layout is ambiguous");
    for (NSString *identifier in @[@"swap", @"translate", @"copy", @"settings", @"mascot", @"brand-name",
                                   @"source-heading", @"output-heading", @"source-language", @"output-language",
                                   @"status", @"instructions"]) {
        NSView *view = FindView(root, identifier);
        Require(view != nil, [@"Missing view: " stringByAppendingString:identifier]);
        if (view.hidden) continue;
        NSRect frame = [view convertRect:view.bounds toView:root];
        Require(frame.size.width > 0 && frame.size.height > 0 &&
                NSContainsRect(NSInsetRect(root.bounds, -0.5, -0.5), frame),
                [@"Control clipped outside panel: " stringByAppendingString:identifier]);
    }
    NSView *header = Control(window, @"header", NSView.class);
    NSView *mascot = Control(window, @"mascot", NSView.class);
    NSTextField *brand = (NSTextField *)Control(window, @"brand-name", NSTextField.class);
    NSRect brandFrame = [brand convertRect:brand.bounds toView:header];
    NSRect mascotFrame = [mascot convertRect:mascot.bounds toView:header];
    // Anchors measure alignment rectangles; text-field frames include native ornament insets.
    NSRect brandAlignment = [brand.superview convertRect:[brand alignmentRectForFrame:brand.frame] toView:header];
    NSRect mascotAlignment = [mascot.superview convertRect:[mascot alignmentRectForFrame:mascot.frame] toView:header];
    CGFloat brandGap = NSMinX(brandAlignment) - NSMaxX(mascotAlignment);
    Require(std::abs(header.bounds.size.height - LoreHeaderHeight) < 1 &&
            std::abs(mascot.bounds.size.width - LoreBrandMarkSize) < 1 &&
            std::abs(mascot.bounds.size.height - LoreBrandMarkSize) < 1 &&
            std::abs(brand.font.pointSize - LoreBrandLogoSize) < 0.1 &&
            std::abs(NSMinX(mascotAlignment) - LoreBrandLeading) < 1 &&
            std::abs(brandGap - LoreBrandGap) < 1,
            [NSString stringWithFormat:
        @"Translator branding must use the shared geometry and typography: "
        @"headerHeight=%.2f expected=%.2f mascotBounds=%@ frame=%@ alignment=%@ expectedSize=%.2f "
        @"leading=%.2f expected=%.2f brandFrame=%@ alignment=%@ font=%.2f expected=%.2f gap=%.2f expected=%.2f",
        header.bounds.size.height, LoreHeaderHeight, NSStringFromRect(mascot.bounds),
        NSStringFromRect(mascotFrame), NSStringFromRect(mascotAlignment), LoreBrandMarkSize,
        NSMinX(mascotAlignment), LoreBrandLeading, NSStringFromRect(brandFrame), NSStringFromRect(brandAlignment),
        brand.font.pointSize, LoreBrandLogoSize, brandGap, LoreBrandGap]);
    Require(NSContainsRect(header.bounds, brandFrame) && !NSIntersectsRect(brandFrame, mascotFrame),
            @"The translator wordmark must fit beside its mascot");
    NSTextView *source = (NSTextView *)Control(window, @"source", NSTextView.class);
    NSTextView *output = (NSTextView *)Control(window, @"output", NSTextView.class);
    NSRect sourcePane = [source.enclosingScrollView convertRect:source.enclosingScrollView.bounds toView:root];
    NSRect outputPane = [output.enclosingScrollView convertRect:output.enclosingScrollView.bounds toView:root];
    NSView *swap = FindView(root, @"swap");
    NSRect swapFrame = [swap convertRect:swap.bounds toView:root];
    Require(std::abs(swapFrame.size.width - swapFrame.size.height) < 1,
            [NSString stringWithFormat:@"Swap must remain square: %@", NSStringFromRect(swapFrame)]);
    Require(!NSIntersectsRect(sourcePane, swapFrame) && !NSIntersectsRect(outputPane, swapFrame),
            @"Swap must stay in the gutter without covering either text pane");
    CGFloat widthDifference = std::abs(sourcePane.size.width - outputPane.size.width);
    CGFloat topDifference = std::abs(NSMinY(sourcePane) - NSMinY(outputPane));
    Require(sourcePane.size.width > 0 && sourcePane.size.height > 0 &&
            outputPane.size.width > 0 && outputPane.size.height > 0 &&
            !NSIntersectsRect(sourcePane, outputPane) &&
            widthDifference < 1 && topDifference < 1,
            [NSString stringWithFormat:@"Text panes must remain equal-width, aligned and non-overlapping: "
                @"source=%@ translation=%@ width_delta=%.3f top_delta=%.3f overlap=%@ scale=%.1f",
                NSStringFromRect(sourcePane), NSStringFromRect(outputPane), widthDifference, topDifference,
                NSIntersectsRect(sourcePane, outputPane) ? @"yes" : @"no", window.backingScaleFactor]);
    CGFloat pixelTolerance = 1.0 / MAX(1.0, window.backingScaleFactor) + 0.01;
    for (NSTextView *text in @[source, output]) {
        NSScrollView *scroll = text.enclosingScrollView;
        CGFloat clipWidth = scroll.contentView.bounds.size.width;
        CGFloat documentWidth = text.frame.size.width;
        CGFloat containerWidth = text.textContainer.containerSize.width;
        Require(!scroll.hasHorizontalScroller && !text.horizontallyResizable &&
                text.textContainer.widthTracksTextView &&
                std::abs(documentWidth - clipWidth) <= pixelTolerance &&
                std::abs(containerWidth - clipWidth) <= pixelTolerance,
                [NSString stringWithFormat:@"Text must wrap to its viewport without horizontal scrolling: "
                    @"%@ clip=%.3f document=%.3f container=%.3f tolerance=%.3f",
                    text.identifier, clipWidth, documentWidth, containerWidth, pixelTolerance]);
    }
    NSView *translate = FindView(root, @"translate");
    NSView *copy = FindView(root, @"copy");
    NSRect translateFrame = [translate convertRect:translate.bounds toView:root];
    NSRect copyFrame = [copy convertRect:copy.bounds toView:root];
    Require(!NSIntersectsRect(translateFrame, copyFrame) &&
            !NSIntersectsRect(sourcePane, translateFrame) && !NSIntersectsRect(outputPane, copyFrame),
            @"Text panes and footer actions must not overlap");
    for (NSString *identifier in @[@"source-heading", @"output-heading", @"source-language", @"output-language"]) {
        NSView *heading = FindView(root, identifier);
        NSRect frame = [heading convertRect:heading.bounds toView:root];
        Require(!NSIntersectsRect(frame, sourcePane) && !NSIntersectsRect(frame, outputPane),
                @"Pane headings must not cover editable or translated text");
    }
}

static void RequireLanguages(NSWindow *window, NSString *source, NSString *output) {
    NSTextField *sourceLabel = (NSTextField *)Control(window, @"source-language", NSTextField.class);
    NSTextField *outputLabel = (NSTextField *)Control(window, @"output-language", NSTextField.class);
    Require([sourceLabel.stringValue isEqualToString:source] && [outputLabel.stringValue isEqualToString:output],
            [NSString stringWithFormat:@"Inaccurate language labels: %@ / %@; expected %@ / %@",
                sourceLabel.stringValue, outputLabel.stringValue, source, output]);
}

static CGFloat BackgroundBrightness(NSWindow *window) {
    Settle(window);
    NSView *root = window.contentView;
    NSBitmapImageRep *bitmap = [root bitmapImageRepForCachingDisplayInRect:root.bounds];
    Require(bitmap != nil, @"Could not capture the panel's theme");
    [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [root cacheDisplayInRect:root.bounds toBitmapImageRep:bitmap];
    }];
    NSInteger x = static_cast<NSInteger>(8 * bitmap.pixelsWide / root.bounds.size.width);
    NSColor *color = [[bitmap colorAtX:x y:bitmap.pixelsHigh / 2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    Require(color != nil, @"Could not read the panel background");
    return color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722;
}

static void Capture(NSWindow *window, NSString *name) {
    Settle(window);
    CheckBounds(window);
    NSView *view = window.contentView;
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    Require(bitmap != nil, @"Could not allocate AppKit view capture");
    [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    }];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *path = [@"panel-smoke" stringByAppendingPathComponent:[name stringByAppendingString:@".png"]];
    Require([png writeToFile:path atomically:YES], @"Could not save AppKit view capture");
}

static void RequireTint(NSWindow *window, NSColor *actual, NSColor *expected, NSString *message) {
    [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
        NSColor *a = [actual colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        NSColor *b = [expected colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        Require(a != nil && b != nil && std::abs(a.redComponent - b.redComponent) < 0.01 &&
                std::abs(a.greenComponent - b.greenComponent) < 0.01 &&
                std::abs(a.blueComponent - b.blueComponent) < 0.01, message);
    }];
}

static void RequireTintInBothAppearances(NSWindow *window, NSColor *actual, NSColor *expected, NSString *message) {
    NSAppearance *previous = window.appearance;
    for (NSAppearanceName appearance in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
        window.appearance = [NSAppearance appearanceNamed:appearance];
        RequireTint(window, actual, expected, message);
    }
    window.appearance = previous;
}

static CGFloat Luminance(NSColor *color) {
    NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    Require(rgb != nil, @"Could not read a rendered contrast color");
    auto linear = [](CGFloat channel) {
        return channel <= 0.04045 ? channel / 12.92 : std::pow((channel + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) +
           0.0722 * linear(rgb.blueComponent);
}

static void CheckPressedPrimaryContrast(NSWindow *window, NSButton *button) {
    NSAppearance *previous = window.appearance;
    NSArray<NSAppearanceName> *appearances = @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua];
    for (NSUInteger i = 0; i < appearances.count; ++i) {
        window.appearance = [NSAppearance appearanceNamed:appearances[i]];
        [button highlight:YES];
        button.needsDisplay = YES;
        Settle(window);
        Require(button.cell.highlighted, @"The contrast capture must show the pressed button");
        NSBitmapImageRep *bitmap = [button bitmapImageRepForCachingDisplayInRect:button.bounds];
        Require(bitmap != nil, @"Could not capture the pressed primary button");
        __block CGFloat foreground = 0;
        [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
            [button cacheDisplayInRect:button.bounds toBitmapImageRep:bitmap];
            foreground = Luminance(button.contentTintColor);
        }];
        // Sample blank face padding, clear of the centered title, border and shadow.
        NSInteger x = static_cast<NSInteger>(8 * bitmap.pixelsWide / button.bounds.size.width);
        CGFloat background = Luminance([bitmap colorAtX:x y:bitmap.pixelsHigh / 2]);
        CGFloat contrast = (MAX(foreground, background) + 0.05) / (MIN(foreground, background) + 0.05);
        Require(contrast >= 4.5, [NSString stringWithFormat:
            @"Pressed primary text must retain 4.5:1 contrast in %@; rendered %.2f:1", appearances[i], contrast]);
        Capture(window, i == 0 ? @"pressed-light" : @"pressed-dark");
        [button highlight:NO];
        button.needsDisplay = YES;
        Require(CATransform3DIsIdentity(button.layer.transform) && [button.layer animationForKey:@"lore.press"] == nil,
                @"Programmatic pressed-color capture must not add motion");
    }
    window.appearance = previous;
}

static NSEvent *KeyEvent(NSWindow *window, NSString *characters,
                         NSEventModifierFlags modifiers, unsigned short keyCode) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                     modifierFlags:modifiers timestamp:NSProcessInfo.processInfo.systemUptime
                      windowNumber:window.windowNumber context:nil characters:characters
       charactersIgnoringModifiers:characters isARepeat:NO keyCode:keyCode];
}

static BOOL PressMotionIsSettled(NSButton *button) {
    CALayer *layer = button.layer;
    if (!CATransform3DIsIdentity(layer.transform)) return NO;
    for (NSString *key in layer.animationKeys) {
        if ([key hasPrefix:@"lore."] && ![key isEqualToString:@"lore.press"]) return NO;
    }
    CAAnimation *animation = [layer animationForKey:@"lore.press"];
    if (!animation) return YES;
    CALayer *presentation = layer.presentationLayer;
    // AppKit may retain one completed client-side record. Check its actual
    // timing and presentation, rather than treating cached metadata as motion.
    return presentation && CATransform3DIsIdentity(presentation.transform) &&
        animation.duration > 0 && animation.duration <= 0.16 &&
        animation.repeatCount == 0 && animation.repeatDuration == 0 && !animation.autoreverses &&
        animation.speed == 1 && animation.timeOffset == 0 && animation.beginTime > 0 &&
        [layer convertTime:CACurrentMediaTime() fromLayer:nil] >= animation.beginTime + animation.duration;
}

static void RequireNoPressMotion(NSButton *button, NSString *stage) {
    CALayer *layer = button.layer;
    CAAnimation *animation = [layer animationForKey:@"lore.press"];
    CATransform3D transform = layer.transform;
    if (PressMotionIsSettled(button)) return;
    CATransform3D presented = layer.presentationLayer.transform;
    Require(NO, [NSString stringWithFormat:
        @"Pointer motion must finish at identity without active or unbounded owned motion: stage=%@ button=%@ "
        @"layer=%@ keys=%@ animation=%@ duration=%.3f beginTime=%.6f animationSpeed=%.3f "
        @"layerSpeed=%.3f layerBeginTime=%.6f timeOffset=%.6f visible=%@ occlusion=%lu "
        @"presentation=%@ presentationScale=(%.6f,%.6f) presentationTranslation=(%.6f,%.6f) model=%@ "
        @"matrix=[%.6f,%.6f,%.6f,%.6f;%.6f,%.6f,%.6f,%.6f;"
        @"%.6f,%.6f,%.6f,%.6f;%.6f,%.6f,%.6f,%.6f]",
        stage, button.identifier, layer, layer.animationKeys, animation, animation.duration,
        animation.beginTime, animation.speed, layer.speed, layer.beginTime, layer.timeOffset,
        button.window.visible ? @"yes" : @"no", static_cast<unsigned long>(button.window.occlusionState),
        [NSValue valueWithCATransform3D:presented], presented.m11, presented.m22, presented.m41, presented.m42,
        [NSValue valueWithCATransform3D:transform],
        transform.m11, transform.m12, transform.m13, transform.m14,
        transform.m21, transform.m22, transform.m23, transform.m24,
        transform.m31, transform.m32, transform.m33, transform.m34,
        transform.m41, transform.m42, transform.m43, transform.m44]);
}

@interface PointerActionProbe : NSObject
@property(nonatomic, weak) id originalTarget;
@property(nonatomic) SEL originalAction;
@property(nonatomic) NSUInteger count;
@property(nonatomic) BOOL releasedBeforeAction;
- (void)invoke:(NSButton *)button;
@end

@implementation PointerActionProbe
- (void)invoke:(NSButton *)button {
    ++self.count;
    self.releasedBeforeAction = self.releasedBeforeAction &&
        CATransform3DIsIdentity(button.layer.transform);
    [NSApp sendAction:self.originalAction to:self.originalTarget from:button];
}
@end

static CGFloat ClickWithPointer(NSButton *button, BOOL held = NO) {
    NSPoint point = [button convertPoint:NSMakePoint(NSMidX(button.bounds), NSMidY(button.bounds)) toView:nil];
    NSTimeInterval timestamp = NSProcessInfo.processInfo.systemUptime;
    NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0
        timestamp:timestamp windowNumber:button.window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
    NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:0
        timestamp:timestamp + (held ? 0.16 : 0.01) windowNumber:button.window.windowNumber context:nil eventNumber:2 clickCount:1 pressure:0];
    __block CGFloat pressedScale = 1;
    NSTimer *release = nil;
    if (held) {
        // A future event timestamp alone does not hold a press. This test-only,
        // one-shot tracking timer lets the real compositor show the pressed state.
        release = [NSTimer timerWithTimeInterval:0.16 repeats:NO block:^(NSTimer *__unused timer) {
            pressedScale = button.layer.presentationLayer.transform.m11;
            [NSApp postEvent:up atStart:YES];
        }];
        [NSRunLoop.mainRunLoop addTimer:release forMode:NSEventTrackingRunLoopMode];
    } else {
        [NSApp postEvent:up atStart:YES];
    }
    @try { [button mouseDown:down]; }
    @finally { [release invalidate]; }
    return pressedScale;
}

static void CheckPointerFeedback(NSButton *copy) {
    PointerActionProbe *probe = [[PointerActionProbe alloc] init];
    probe.originalTarget = copy.target;
    probe.originalAction = copy.action;
    probe.releasedBeforeAction = YES;
    NSRect frame = copy.frame;
    copy.target = probe;
    copy.action = @selector(invoke:);
    @try {
        ClickWithPointer(copy);
        ClickWithPointer(copy);
        CGFloat pressedScale = ClickWithPointer(copy, YES);
        Require(probe.count == 3 && probe.releasedBeforeAction,
                @"Pointer actions must run once per click and release before forwarding");
        Require(NSEqualRects(frame, copy.frame), @"Press feedback must not change layout or hit testing");
        CAAnimation *animation = [copy.layer animationForKey:@"lore.press"];
        if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
            Require(animation == nil, @"Reduce Motion must keep pointer feedback immediate");
        } else {
            Require(pressedScale >= 0.97 && pressedScale < 0.999,
                    @"A held pointer press must visibly scale before its action runs");
            Require(animation != nil && animation.duration > 0 && animation.duration <= 0.16 &&
                    animation.repeatCount == 0 && animation.repeatDuration == 0 &&
                    !animation.autoreverses && animation.removedOnCompletion,
                    @"Pointer feedback must be a finite, automatically removed animation");
        }
        // Submit the displayed layer tree, then service AppKit while waiting
        // for the compositor's completion event.
        [copy.window displayIfNeeded];
        [CATransaction flush];
        NSTimeInterval waitStarted = NSProcessInfo.processInfo.systemUptime;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.5];
        while (!PressMotionIsSettled(copy) && deadline.timeIntervalSinceNow > 0) {
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]
                inMode:NSDefaultRunLoopMode dequeue:YES];
            if (event) [NSApp sendEvent:event];
            [NSApp updateWindows];
        }
        RequireNoPressMotion(copy, [NSString stringWithFormat:@"after pointer completion wait (elapsed %.3fs)",
            NSProcessInfo.processInfo.systemUptime - waitStarted]);
    } @finally {
        copy.target = probe.originalTarget;
        copy.action = probe.originalAction;
    }
}

static void RunSmoke(void) {
    const char *expectedMotion = std::getenv("LORE_EXPECT_REDUCE_MOTION");
    if (expectedMotion) {
        Require(NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion ==
                (std::atoi(expectedMotion) != 0), @"OS Reduce Motion does not match this test run");
    }
    Require([NSFileManager.defaultManager createDirectoryAtPath:@"panel-smoke"
            withIntermediateDirectories:YES attributes:nil error:nil], @"Cannot create capture directory");
    [@"These are AppKit content-view captures from a model-free lifecycle smoke test.\n"
      @"They do not verify OS window chrome, popup interaction, focus in other apps,\n"
      @"real inference, or actual-app CPU/memory regression. Those checks remain separate.\n"
       writeToFile:@"panel-smoke/README.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSString *english = @"The meeting has been moved to next Monday.\nPlease review the updated document.";
    NSString *japanese = @"会議は来週の月曜日に変更されました。\n更新された資料を確認してください。";
    TranslationPanel *panel = [[TranslationPanel alloc] init];
    __block NSUInteger translations = 0, cancellations = 0, closes = 0, settings = 0;
    __block lore::Direction lastDirection = lore::Direction::Automatic;
    __block NSString *lastInput = nil;
    panel.onTranslate = ^(NSString *text, lore::Direction direction) {
        ++translations;
        lastInput = text;
        lastDirection = direction;
    };
    panel.onCancel = ^{ ++cancellations; };
    panel.onClose = ^{ ++closes; };
    panel.onSettings = ^{ ++settings; };

    [panel showForManualInput];
    NSWindow *window = PanelWindow();
    Settle(window);
    Require(std::abs(window.frame.size.width - 720) < 1 &&
            std::abs(window.frame.size.height - 500) < 1, @"Unexpected initial panel size");
    Require(std::abs(window.minSize.width - 640) < 1 &&
            std::abs(window.minSize.height - 420) < 1, @"Unexpected minimum panel size");
    NSTextView *source = (NSTextView *)Control(window, @"source", NSTextView.class);
    NSTextView *output = (NSTextView *)Control(window, @"output", NSTextView.class);
    NSButton *swap = (NSButton *)Control(window, @"swap", NSButton.class);
    NSButton *translate = (NSButton *)Control(window, @"translate", NSButton.class);
    NSButton *copy = (NSButton *)Control(window, @"copy", NSButton.class);
    NSButton *settingsButton = (NSButton *)Control(window, @"settings", NSButton.class);
    Require(FindView(window.contentView, @"dismiss") == nil,
            @"The redundant close control must not remain beside Settings");
    NSButton *closeButton = [window standardWindowButton:NSWindowCloseButton];
    for (NSNumber *kind in @[@(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton)]) {
        NSButton *standardButton = [window standardWindowButton:static_cast<NSWindowButton>(kind.integerValue)];
        Require(standardButton != nil && !standardButton.hidden,
                @"Native window controls must remain visible");
    }
    NSImageView *mascot = (NSImageView *)Control(window, @"mascot", NSImageView.class);
    Require(mascot.image != nil && LoreMascotImage() != nil && LorePaperImage() != nil,
            @"Native captures must load the real mascot and paper assets");
    RequireLanguages(window, @"AUTO", @"—");
    NSTextField *status = (NSTextField *)Control(window, @"status", NSTextField.class);
    Require(source.editable && source.selectable && !output.editable && output.selectable,
            @"Source/output editing contract changed");
    Require(source.enclosingScrollView != output.enclosingScrollView &&
            source.enclosingScrollView.hasVerticalScroller && output.enclosingScrollView.hasVerticalScroller,
            @"Text panes must scroll independently");

    [panel setAvailable:YES busy:NO status:@"" kind:LoreStatusInformation];
    [panel showForSelection:@" \n"];
    Require(!translate.enabled && !copy.enabled && !swap.enabled,
            @"Empty source/output must disable their actions");
    NSInteger emptyCopyCount = NSPasteboard.generalPasteboard.changeCount;
    [window performKeyEquivalent:KeyEvent(window, @"C",
        NSEventModifierFlagCommand | NSEventModifierFlagShift, 8)];
    Require(NSPasteboard.generalPasteboard.changeCount == emptyCopyCount,
            @"Command-Shift-C must leave the clipboard unchanged when output is empty");
    [panel showForSelection:english];
    RequireLanguages(window, @"AUTO", @"—");
    Require(translate.enabled && !copy.enabled && !swap.enabled,
            @"Nonempty source must enable translation only");
    CheckPressedPrimaryContrast(window, translate);
    [translate performClick:nil];
    Require(lastDirection == lore::Direction::Automatic && [lastInput isEqualToString:english],
            @"Fresh input must translate automatically");
    [panel setOutput:japanese direction:lore::Direction::EnglishToJapanese];
    RequireLanguages(window, @"EN", @"JA");
    source.string = japanese;
    [source didChangeText];
    RequireLanguages(window, @"AUTO", @"JA");
    [panel setOutput:[japanese stringByAppendingString:@"\n"] direction:lore::Direction::EnglishToJapanese];
    RequireLanguages(window, @"AUTO", @"JA");
    [panel showForSelection:english];
    [panel setOutput:japanese direction:lore::Direction::EnglishToJapanese];
    NSUInteger beforeSwap = translations;
    [swap performClick:nil];
    Require(translations == beforeSwap + 1 && [source.string isEqualToString:japanese] &&
            output.string.length == 0 && !swap.enabled && !copy.enabled &&
            [lastInput isEqualToString:japanese] && lastDirection == lore::Direction::JapaneseToEnglish,
            @"Swap must move the translation into source, clear output and translate back once");
    [panel setOutput:english direction:lore::Direction::JapaneseToEnglish];
    RequireLanguages(window, @"JA", @"EN");
    [panel setAvailable:YES busy:YES status:@"Translating…" kind:LoreStatusInformation];
    NSRect recallFrame = window.frame;
    recallFrame.origin.x += 17;
    recallFrame.origin.y += 23;
    [window setFrame:recallFrame display:NO];
    recallFrame = window.frame;
    [window makeFirstResponder:output];
    NSUInteger beforeRecall = translations;
    [panel showForManualInput];
    Require(NSEqualRects(window.frame, recallFrame) && window.firstResponder == source &&
            [source.string isEqualToString:japanese] && [output.string isEqualToString:english] &&
            [translate.title isEqualToString:@"Cancel  ⌘↵"] && !swap.enabled &&
            [status.stringValue isEqualToString:@"Translating…"] &&
            translations == beforeRecall && cancellations == 0,
            @"Recalling a visible panel must preserve its position, text and busy state while focusing source");
    [window performKeyEquivalent:KeyEvent(window, @"\r", NSEventModifierFlagCommand, 36)];
    Require(translations == beforeRecall && cancellations == 1 && lastDirection == lore::Direction::JapaneseToEnglish,
            @"Command-Return must cancel a recalled busy panel once without losing its swapped direction");
    [panel setAvailable:YES busy:NO status:@"" kind:LoreStatusInformation];
    [translate performClick:nil];
    Require(lastDirection == lore::Direction::JapaneseToEnglish,
            @"Retranslation must retain the swapped direction");
    [swap performClick:nil];
    Require([lastInput isEqualToString:english] && lastDirection == lore::Direction::EnglishToJapanese,
            @"A second swap must reverse the direction again");
    [panel showForSelection:japanese];
    [panel setOutput:@"Visit 東京 tomorrow." direction:lore::Direction::JapaneseToEnglish];
    [swap performClick:nil];
    Require([lastInput isEqualToString:@"Visit 東京 tomorrow."] &&
            lastDirection == lore::Direction::EnglishToJapanese,
            @"Mixed-script output must reverse its actual direction instead of being detected again");
    source.string = japanese;
    [source didChangeText];
    RequireLanguages(window, @"AUTO", @"—");
    [panel setOutput:@"Output from the previous request" direction:lore::Direction::EnglishToJapanese];
    RequireLanguages(window, @"AUTO", @"JA");
    [translate performClick:nil];
    Require(lastDirection == lore::Direction::Automatic,
            @"Editing swapped input must restore automatic direction");
    [panel setOutput:@"" direction:lore::Direction::Automatic];
    RequireLanguages(window, @"AUTO", @"—");
    [panel setOutput:english direction:lore::Direction::JapaneseToEnglish];
    RequireLanguages(window, @"JA", @"EN");
    [panel setAvailable:YES busy:YES status:@"" kind:LoreStatusInformation];
    NSUInteger beforeDisabledSwap = translations;
    [swap performClick:nil];
    Require(!swap.enabled && translations == beforeDisabledSwap && [source.string isEqualToString:japanese],
            @"Swap must not move partial text while translation is running");
    [panel setAvailable:NO busy:NO status:@"Loading the model…" kind:LoreStatusInformation];
    [swap performClick:nil];
    Require(!swap.enabled && translations == beforeDisabledSwap,
            @"Swap must remain disabled while the model is unavailable");
    [panel setAvailable:YES busy:NO status:@"" kind:LoreStatusInformation];
    [panel showForSelection:english];
    [translate performClick:nil];
    Require(lastDirection == lore::Direction::Automatic && !swap.enabled,
            @"New selected text must reset automatic direction and clear the previous swap result");
    [settingsButton performClick:nil];
    Require(settings == 1, @"Settings callback was not routed");
    [panel setOutput:japanese direction:lore::Direction::EnglishToJapanese];
    Require([source.string isEqualToString:english] && [output.string isEqualToString:japanese],
            @"Source and translation text must remain unmodified");
    [copy performClick:nil];
    Require([[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] isEqualToString:japanese],
            @"Copy action must write the exact translated text");
    Require([copy.title isEqualToString:@"Copied"] && copy.image != nil,
            @"Successful copying must confirm without changing the translated content");
    RequireNoPressMotion(copy, @"programmatic copy before pointer input");
    [panel setOutput:[japanese stringByAppendingString:@"\n"] direction:lore::Direction::EnglishToJapanese];
    [window performKeyEquivalent:KeyEvent(window, @"C",
        NSEventModifierFlagCommand | NSEventModifierFlagShift, 8)];
    Require([[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString]
                isEqualToString:[japanese stringByAppendingString:@"\n"]] &&
            [copy.title isEqualToString:@"Copied"],
            @"Command-Shift-C must copy exact output and show the normal copy confirmation");
    RequireNoPressMotion(copy, @"Command-Shift-C before pointer input");
    [panel setOutput:japanese direction:lore::Direction::EnglishToJapanese];
    [window performKeyEquivalent:KeyEvent(window, @"C",
        NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagCapsLock, 8)];
    Require([[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] isEqualToString:japanese],
            @"Caps Lock must not disable Command-Shift-C");
    NSInteger copiedCount = NSPasteboard.generalPasteboard.changeCount;
    for (NSNumber *extra in @[@(NSEventModifierFlagControl), @(NSEventModifierFlagOption)]) {
        [window performKeyEquivalent:KeyEvent(window, @"C",
            NSEventModifierFlagCommand | NSEventModifierFlagShift | extra.unsignedIntegerValue, 8)];
    }
    Require(NSPasteboard.generalPasteboard.changeCount == copiedCount,
            @"Extra modifiers must not trigger accidental translation copying");
    RequireNoPressMotion(copy, @"Command-Shift-C with Caps Lock");
    Capture(window, @"copied");
    [panel setOutput:japanese direction:lore::Direction::EnglishToJapanese];
    Require([copy.title isEqualToString:@"Copied"],
            @"Identical final output must preserve the copy confirmation");
    [panel setOutput:[japanese stringByAppendingString:@"\n"] direction:lore::Direction::EnglishToJapanese];
    Require([copy.title isEqualToString:@"Copy Translation"],
            @"New translation output must reset stale copy confirmation");
    [panel setOutput:japanese direction:lore::Direction::EnglishToJapanese];
    CheckPointerFeedback(copy);
    Require([copy.title isEqualToString:@"Copied"] &&
            [[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] isEqualToString:japanese],
            @"Pointer copy feedback must preserve clipboard content");
    [panel showForSelection:english];
    Require([copy.title isEqualToString:@"Copy Translation"] && !copy.enabled,
            @"A new selected passage must clear the previous copy confirmation");
    [panel setOutput:japanese direction:lore::Direction::EnglishToJapanese];
    RequireNoPressMotion(copy, @"new passage and output after pointer input");
    RequireNoPressMotion(translate, @"new passage and output after pointer input");

    NSTextField *instructions = (NSTextField *)Control(window, @"instructions", NSTextField.class);
    [panel setShortcutInstructions:@"Translate Selection: ⌃T twice · Open Translator: ⌥T twice"];
    Require(!instructions.hidden && [instructions.stringValue isEqualToString:
                @"Translate Selection: ⌃T twice · Open Translator: ⌥T twice"],
            @"The existing helper must display the current shortcut assignments");
    [panel setShortcutInstructions:@""];
    Require(instructions.hidden, @"An empty shortcut helper must leave no extra message row");

    [panel setShortcutAvailable:YES];
    [panel showForSelection:english];
    [panel setOutput:japanese direction:lore::Direction::EnglishToJapanese];
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    Capture(window, @"dark");
    CGFloat darkBrightness = BackgroundBrightness(window);
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    Capture(window, @"light");
    Require(BackgroundBrightness(window) > darkBrightness + 0.3,
            @"Changing appearance on the visible panel must repaint its paper background");
    // AppKit selects accessibility appearances from the OS preference. Assigning
    // high-contrast appearance names directly does not exercise Increase Contrast.
    [window setContentSize:NSMakeSize(640, 420)];
    [panel setShortcutAvailable:NO];
    [panel setAvailable:YES busy:NO status:@"The input exceeds the 4,096-token limit. Select a shorter passage and translate again." kind:LoreStatusWarning];
    RequireTintInBothAppearances(window, status.textColor, LoreColor(LoreWarning),
            @"Input-limit warnings must use the shared warning color");
    Capture(window, @"minimum-permission-error");
    [window setContentSize:NSMakeSize(720, 500)];
    [panel setShortcutAvailable:YES];
    [panel setAvailable:NO busy:NO status:@"Downloading the model… 43%" kind:LoreStatusInformation];
    Require(!translate.enabled && !swap.enabled, @"Translation and swap must wait for model readiness");
    RequireTintInBothAppearances(window, status.textColor, LoreColor(LoreSecondaryText),
            @"Model preparation must use the informational status color");
    Capture(window, @"model-setup");
    [panel setAvailable:YES busy:YES status:@"" kind:LoreStatusInformation];
    [panel setOutput:@"会議は来週" direction:lore::Direction::EnglishToJapanese];
    Require([translate.title isEqualToString:@"Cancel  ⌘↵"] && translate.enabled && copy.enabled,
            @"Busy state must offer cancellation and partial-output copying");
    NSUInteger beforeKey = translations;
    NSUInteger beforeKeyCancellations = cancellations;
    [window performKeyEquivalent:KeyEvent(window, @"\r", NSEventModifierFlagCommand, 36)];
    Require(translations == beforeKey && cancellations == beforeKeyCancellations + 1,
            @"Command-Return must cancel once while busy without starting another translation");
    [window performKeyEquivalent:KeyEvent(window, @"\r",
        NSEventModifierFlagCommand | NSEventModifierFlagCapsLock, 36)];
    Require(translations == beforeKey && cancellations == beforeKeyCancellations + 2,
            @"Caps Lock must not disable the Command-Return cancellation action");
    for (NSNumber *extra in @[@(NSEventModifierFlagControl), @(NSEventModifierFlagOption),
                              @(NSEventModifierFlagShift)]) {
        [window performKeyEquivalent:KeyEvent(window, @"\r",
            NSEventModifierFlagCommand | extra.unsignedIntegerValue, 36)];
    }
    Require(translations == beforeKey && cancellations == beforeKeyCancellations + 2,
            @"Extra modifiers must not trigger either translation or cancellation");
    RequireNoPressMotion(translate, @"Command-Return while busy");
    RequireNoPressMotion(copy, @"Command-Return while busy");
    [translate performClick:nil];
    Require(cancellations == beforeKeyCancellations + 3 && translations == beforeKey,
            @"The busy button must cancel once, matching Command-Return");
    [panel setAvailable:YES busy:NO status:@"The model could not translate this passage." kind:LoreStatusError];
    RequireTintInBothAppearances(window, status.textColor, LoreColor(LoreError),
            @"Translation failures must use the same error color as Settings");
    Capture(window, @"translation-error");
    [panel setAvailable:YES busy:NO status:@"Translation cancelled" kind:LoreStatusInformation];
    RequireTintInBothAppearances(window, status.textColor, LoreColor(LoreSecondaryText),
            @"Informational messages must clear the previous error styling");
    Capture(window, @"cancelled");

    // Warm both native text/theme states before establishing object identity baselines.
    [panel showForSelection:english];
    [panel setOutput:japanese direction:lore::Direction::EnglishToJapanese];
    [panel setAvailable:YES busy:NO status:@"" kind:LoreStatusInformation];
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    Settle(window);
    NSMutableSet<NSValue *> *baselineViews = [NSMutableSet set];
    NSMutableSet<NSValue *> *baselineConstraints = [NSMutableSet set];
    CollectObjects(window.contentView, baselineViews, baselineConstraints);
    Require(baselineConstraints.count > 0, @"No explicitly identified app constraints were found");
    NSUInteger beforeLifecycleCancellations = cancellations;
    for (NSUInteger iteration = 0; iteration < 20; ++iteration) {
        @autoreleasepool {
            [panel showForSelection:english];
            [panel setAvailable:YES busy:NO status:@"" kind:LoreStatusInformation];
            [translate performClick:nil];
            [panel setAvailable:YES busy:YES status:@"" kind:LoreStatusInformation];
            [panel setOutput:@"会議" direction:lore::Direction::EnglishToJapanese];
            [panel setOutput:japanese direction:lore::Direction::EnglishToJapanese];
            [panel setAvailable:YES busy:NO status:@"" kind:LoreStatusInformation];
            [translate performClick:nil];
            [panel setAvailable:YES busy:YES status:@"" kind:LoreStatusInformation];
            [panel setOutput:@"会議は" direction:lore::Direction::EnglishToJapanese];
            [translate performClick:nil];
            [panel setAvailable:YES busy:NO status:@"Translation cancelled" kind:LoreStatusInformation];
            window.appearance = [NSAppearance appearanceNamed:iteration % 2
                ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
            [panel close];
            Require([copy.layer animationForKey:@"lore.press"] == nil &&
                    [translate.layer animationForKey:@"lore.press"] == nil,
                    @"Closing must remove owned animation records");
            [panel showWithoutChangingInput];
            Settle(window);
            Require(PanelWindow() == window, @"Panel was recreated during its lifecycle");
            NSMutableSet<NSValue *> *views = [NSMutableSet set];
            NSMutableSet<NSValue *> *constraints = [NSMutableSet set];
            CollectObjects(window.contentView, views, constraints);
            Require([views isEqualToSet:baselineViews] && [constraints isEqualToSet:baselineConstraints],
                    @"App views or explicit constraints were recreated during updates");
            NSString *motionStage = [NSString stringWithFormat:@"lifecycle cycle %lu after close/reopen",
                static_cast<unsigned long>(iteration + 1)];
            RequireNoPressMotion(copy, motionStage);
            RequireNoPressMotion(translate, motionStage);
            CheckBounds(window);
        }
    }
    Require(cancellations == beforeLifecycleCancellations + 20 && closes == 20,
            @"Repeated lifecycle callbacks were lost or duplicated");
    [copy performClick:nil];
    Require([copy.title isEqualToString:@"Copied"], @"Copy confirmation must remain available after reuse");
    [closeButton performClick:nil];
    Require(closes == 21 && !window.visible, @"The native close button must use the close callback");
    Require([copy.title isEqualToString:@"Copy Translation"], @"Closing must clear copy confirmation");
    RequireNoPressMotion(copy, @"native close after lifecycle cycles");
    RequireNoPressMotion(translate, @"native close after lifecycle cycles");
    [panel showForManualInput];
    Settle(window);
    [window sendEvent:KeyEvent(window, @"\033", 0, 53)];
    Settle(window);
    Require(closes == 22, @"Escape must close the panel through its close callback");
    [panel showForManualInput];
    Settle(window);
    Require([window performKeyEquivalent:KeyEvent(window, @"w", NSEventModifierFlagCommand, 13)] &&
            closes == 23 && !window.visible, @"Command-W must use the same close callback");
    std::cout << "panel_smoke_complete=true\nreused_panel_cycles=20\n"
              << "app_view_count=" << baselineViews.count << '\n'
              << "app_constraint_count=" << baselineConstraints.count << '\n'
              << "reduce_motion_enabled=" << static_cast<bool>(NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) << '\n'
              << "increase_contrast_enabled=" << static_cast<bool>(NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast) << '\n'
              << "captures=panel-smoke (AppKit views; not full UI/resource validation)\n";
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        __block int result = EXIT_FAILURE;
        // A long main-GCD block cannot service completion work queued back to
        // that same serial queue. Start on the run loop so nested AppKit events
        // can deliver Core Animation's completion normally.
        [NSRunLoop.mainRunLoop performBlock:^{
            @try {
                try {
                    RunSmoke();
                    result = EXIT_SUCCESS;
                } catch (const std::exception &error) {
                    std::cerr << "Panel smoke failed: " << error.what() << '\n';
                }
            } @catch (NSException *exception) {
                std::cerr << "Panel smoke failed: " << exception.reason.UTF8String << '\n';
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
