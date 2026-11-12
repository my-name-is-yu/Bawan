#import "TranslationPanel.h"
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
    for (NSString *identifier in @[@"direction", @"translate", @"copy", @"settings", @"dismiss",
                                   @"status", @"instructions"]) {
        NSView *view = FindView(root, identifier);
        Require(view != nil, [@"Missing view: " stringByAppendingString:identifier]);
        if (view.hidden) continue;
        NSRect frame = [view convertRect:view.bounds toView:root];
        Require(frame.size.width > 0 && frame.size.height > 0 &&
                NSContainsRect(NSInsetRect(root.bounds, -0.5, -0.5), frame),
                [@"Control clipped outside panel: " stringByAppendingString:identifier]);
    }
    NSTextView *source = (NSTextView *)Control(window, @"source", NSTextView.class);
    NSTextView *output = (NSTextView *)Control(window, @"output", NSTextView.class);
    NSRect sourcePane = [source.enclosingScrollView convertRect:source.enclosingScrollView.bounds toView:root];
    NSRect outputPane = [output.enclosingScrollView convertRect:output.enclosingScrollView.bounds toView:root];
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

    NSString *english = @"The meeting has been moved to next Monday. Please review the updated document and send your feedback by Friday.";
    NSString *japanese = @"会議は来週の月曜日に変更されました。更新された資料を確認し、金曜日までにフィードバックをお送りください。";
    TranslationPanel *panel = [[TranslationPanel alloc] init];
    __block NSUInteger translations = 0, cancellations = 0, closes = 0, settings = 0;
    __block NSInteger lastDirection = -1;
    __block NSString *lastInput = nil;
    panel.onTranslate = ^(NSString *text, NSInteger direction) {
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
    NSPopUpButton *direction = (NSPopUpButton *)Control(window, @"direction", NSPopUpButton.class);
    NSButton *translate = (NSButton *)Control(window, @"translate", NSButton.class);
    NSButton *copy = (NSButton *)Control(window, @"copy", NSButton.class);
    NSButton *settingsButton = (NSButton *)Control(window, @"settings", NSButton.class);
    NSButton *dismiss = (NSButton *)Control(window, @"dismiss", NSButton.class);
    Require(source.editable && source.selectable && !output.editable && output.selectable,
            @"Source/output editing contract changed");
    Require(source.enclosingScrollView != output.enclosingScrollView &&
            source.enclosingScrollView.hasVerticalScroller && output.enclosingScrollView.hasVerticalScroller,
            @"Text panes must scroll independently");

    [panel setAvailable:YES busy:NO status:@""];
    [panel showForSelection:@" \n"];
    Require(!translate.enabled && !copy.enabled, @"Empty source/output must disable their actions");
    [panel showForSelection:english];
    Require(translate.enabled && !copy.enabled, @"Nonempty source must enable translation only");
    Require(direction.numberOfItems == 3, @"Only automatic, English/Japanese directions are supported");
    for (NSInteger index = 0; index < 3; ++index) {
        [direction selectItemAtIndex:index];
        [translate performClick:nil];
        Require(panel.directionIndex == index && lastDirection == index && [lastInput isEqualToString:english],
                @"Translation callback must retain the direction index and source content");
    }
    [direction selectItemAtIndex:0];
    [settingsButton performClick:nil];
    Require(settings == 1, @"Settings callback was not routed");
    [panel setOutput:japanese];
    Require([source.string isEqualToString:english] && [output.string isEqualToString:japanese],
            @"Source and translation text must remain unmodified");
    [copy performClick:nil];
    Require([[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] isEqualToString:japanese],
            @"Copy action must write the exact translated text");
    Require([copy.title isEqualToString:@"Copied"] && copy.image != nil,
            @"Successful copying must confirm without changing the translated content");
    RequireNoPressMotion(copy, @"programmatic copy before pointer input");
    Capture(window, @"copied");
    [panel setOutput:japanese];
    Require([copy.title isEqualToString:@"Copied"],
            @"Identical final output must preserve the copy confirmation");
    [panel setOutput:[japanese stringByAppendingString:@"\n"]];
    Require([copy.title isEqualToString:@"Copy Translation"],
            @"New translation output must reset stale copy confirmation");
    [panel setOutput:japanese];
    CheckPointerFeedback(copy);
    Require([copy.title isEqualToString:@"Copied"] &&
            [[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] isEqualToString:japanese],
            @"Pointer copy feedback must preserve clipboard content");
    [panel showForSelection:english];
    Require([copy.title isEqualToString:@"Copy Translation"] && !copy.enabled,
            @"A new selected passage must clear the previous copy confirmation");
    [panel setOutput:japanese];
    RequireNoPressMotion(copy, @"new passage and output after pointer input");
    RequireNoPressMotion(translate, @"new passage and output after pointer input");

    [panel setShortcutAvailable:YES];
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    Capture(window, @"dark");
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    Capture(window, @"light");
    // AppKit selects accessibility appearances from the OS preference. Assigning
    // high-contrast appearance names directly does not exercise Increase Contrast.
    [window setContentSize:NSMakeSize(640, 420)];
    [panel setShortcutAvailable:NO];
    [panel setAvailable:YES busy:NO status:@"The input exceeds the 4,096-token limit. Select a shorter passage and translate again."];
    Capture(window, @"minimum-permission-error");
    [window setContentSize:NSMakeSize(720, 500)];
    [panel setShortcutAvailable:YES];
    [panel setAvailable:NO busy:NO status:@"Downloading the model… 43%"];
    Require(!translate.enabled, @"Translation must be disabled before model readiness");
    Capture(window, @"model-setup");
    [panel setAvailable:YES busy:YES status:@""];
    [panel setOutput:@"会議は来週"];
    Require([translate.title isEqualToString:@"Cancel"] && translate.enabled && copy.enabled,
            @"Busy state must offer cancellation and partial-output copying");
    NSUInteger beforeKey = translations;
    [window performKeyEquivalent:KeyEvent(window, @"\r", NSEventModifierFlagCommand, 36)];
    Require(translations == beforeKey + 1, @"Command-Return must retranslate while busy");
    [window performKeyEquivalent:KeyEvent(window, @"\r",
        NSEventModifierFlagCommand | NSEventModifierFlagCapsLock, 36)];
    Require(translations == beforeKey + 2, @"Caps Lock must not disable Command-Return");
    for (NSNumber *extra in @[@(NSEventModifierFlagControl), @(NSEventModifierFlagOption),
                              @(NSEventModifierFlagShift)]) {
        [window performKeyEquivalent:KeyEvent(window, @"\r",
            NSEventModifierFlagCommand | extra.unsignedIntegerValue, 36)];
    }
    Require(translations == beforeKey + 2, @"Modified Return must not trigger accidental retranslations");
    RequireNoPressMotion(translate, @"Command-Return while busy");
    RequireNoPressMotion(copy, @"Command-Return while busy");
    [translate performClick:nil];
    Require(cancellations == 1, @"Busy action must route cancellation");
    [panel setAvailable:YES busy:NO status:@"Translation cancelled"];
    Capture(window, @"cancelled");

    // Warm both native text/theme states before establishing object identity baselines.
    [panel showForSelection:english];
    [panel setOutput:japanese];
    [panel setAvailable:YES busy:NO status:@""];
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    Settle(window);
    NSMutableSet<NSValue *> *baselineViews = [NSMutableSet set];
    NSMutableSet<NSValue *> *baselineConstraints = [NSMutableSet set];
    CollectObjects(window.contentView, baselineViews, baselineConstraints);
    Require(baselineConstraints.count > 0, @"No explicitly identified app constraints were found");
    for (NSUInteger iteration = 0; iteration < 20; ++iteration) {
        @autoreleasepool {
            [panel showForSelection:english];
            [panel setAvailable:YES busy:NO status:@""];
            [translate performClick:nil];
            [panel setAvailable:YES busy:YES status:@""];
            [panel setOutput:@"会議"];
            [panel setOutput:japanese];
            [panel setAvailable:YES busy:NO status:@""];
            [translate performClick:nil];
            [panel setAvailable:YES busy:YES status:@""];
            [panel setOutput:@"会議は"];
            [translate performClick:nil];
            [panel setAvailable:YES busy:NO status:@"Translation cancelled"];
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
    Require(cancellations == 21 && closes == 20, @"Repeated lifecycle callbacks were lost or duplicated");
    [copy performClick:nil];
    Require([copy.title isEqualToString:@"Copied"], @"Copy confirmation must remain available after reuse");
    [dismiss performClick:nil];
    Require(closes == 21, @"Dismiss button must use the close callback");
    Require([copy.title isEqualToString:@"Copy Translation"], @"Closing must clear copy confirmation");
    RequireNoPressMotion(copy, @"dismiss button after lifecycle cycles");
    RequireNoPressMotion(translate, @"dismiss button after lifecycle cycles");
    [panel showForManualInput];
    Settle(window);
    [window sendEvent:KeyEvent(window, @"\033", 0, 53)];
    Settle(window);
    Require(closes == 22, @"Escape must close the panel through its close callback");
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
