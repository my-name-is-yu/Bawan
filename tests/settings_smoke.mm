#import "SettingsViewController.h"
#import "TranslationPanel.h"
#import <CoreGraphics/CoreGraphics.h>
#import "BawanAppearance.h"
#import "BawanChrome.h"

#include <cstdlib>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <set>

#import "WindowDragChecks.h"

@interface SmokeShortcutMonitor : ShortcutMonitor {
    ShortcutPreferences *_testPreferences;
    BOOL _testSuspended;
    BOOL _testConfigurationActive;
}
@property(nonatomic) ShortcutAvailability selectionAvailability;
@property(nonatomic) ShortcutAvailability panelAvailability;
@property(nonatomic) BOOL permissionsGranted;
@property(nonatomic) NSUInteger permissionRequests;
@property(nonatomic) bawan::ShortcutAction lastPermissionAction;
@end

@implementation SmokeShortcutMonitor
- (instancetype)initWithPreferences:(ShortcutPreferences *)preferences {
    self = [super initWithPreferences:preferences];
    if (self) {
        _testPreferences = preferences;
        _selectionAvailability = ShortcutAvailabilityNeedsInputMonitoring;
        _panelAvailability = ShortcutAvailabilityNeedsAccessibility;
    }
    return self;
}
- (void)start {}
- (void)stop {}
- (void)refresh {
    if (_permissionsGranted) {
        _selectionAvailability = ShortcutAvailabilityAvailable;
        _panelAvailability = ShortcutAvailabilityAvailable;
    }
}
- (BOOL)suspended { return _testSuspended; }
- (void)setSuspended:(BOOL)value { _testSuspended = value; }
- (BOOL)configurationActive { return _testConfigurationActive; }
- (void)setConfigurationActive:(BOOL)value { _testConfigurationActive = value; }
- (ShortcutAvailability)availabilityForAction:(bawan::ShortcutAction)action {
    if (![_testPreferences bindingForAction:action].enabled) return ShortcutAvailabilityOff;
    return action == bawan::ShortcutAction::TranslateSelection ? _selectionAvailability : _panelAvailability;
}
- (void)requestPermissionForAction:(bawan::ShortcutAction)action {
    ++_permissionRequests;
    _lastPermissionAction = action;
}
@end

@interface SmokeSettingsViewController : SettingsViewController {
    std::set<CGKeyCode> _testHeldKeys;
}
- (void)setRecordedKey:(CGKeyCode)key down:(BOOL)down;
@end
@implementation SmokeSettingsViewController
- (void)setRecordedKey:(CGKeyCode)key down:(BOOL)down {
    if (down) _testHeldKeys.insert(key);
    else _testHeldKeys.erase(key);
}
- (BOOL)isRecordingKeyDown:(CGKeyCode)key { return _testHeldKeys.count(key) != 0; }
@end

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

static void Settle(NSWindow *window) {
    [window.contentView layoutSubtreeIfNeeded];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    [window.contentView layoutSubtreeIfNeeded];
}

static void CheckFrameDragging(NSWindow *window) {
    NSRect originalFrame = window.frame;
    NSAppearance *originalAppearance = window.appearance;
    NSView *root = window.contentView;
    NSView *header = FindView(root, @"settings-header");
    NSView *mascot = FindView(root, @"settings-mascot");
    NSButton *close = (NSButton *)FindView(root, @"settings-close");
    NSView *scroll = FindView(root, @"settings-scroll");
    Require(window.movable && window.movableByWindowBackground,
        @"The Settings masthead must share native background dragging with the translator");
    for (NSValue *size in @[[NSValue valueWithSize:NSMakeSize(720, 500)],
                            [NSValue valueWithSize:NSMakeSize(640, 420)]]) {
        NSRect frame = window.frame;
        frame.size = size.sizeValue;
        [window setFrame:frame display:NO];
        for (NSAppearanceName appearance in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
            window.appearance = [NSAppearance appearanceNamed:appearance];
            Settle(window);
            CheckBackgroundDragGrid(window, header, @[mascot, close]);
            CheckBackgroundDragCenter(window, mascot, NO);
            CheckBackgroundDragCenter(window, close, NO);
            CheckBackgroundDragPoint(window, scroll, NSMakePoint(8, NSMidY(scroll.bounds)), NO, scroll);
        }
    }
    window.appearance = originalAppearance;
    [window setFrame:originalFrame display:NO];
    Settle(window);
}

static void RequireOrdinaryWindow(NSWindow *window, NSString *stage) {
    NSWindowCollectionBehavior pinned = NSWindowCollectionBehaviorCanJoinAllSpaces;
    Require([window isKindOfClass:NSPanel.class] && !((NSPanel *)window).floatingPanel &&
        window.level == NSNormalWindowLevel && !window.hidesOnDeactivate &&
        (window.collectionBehavior & pinned) == 0 &&
        (window.collectionBehavior & NSWindowCollectionBehaviorMoveToActiveSpace) != 0,
        [NSString stringWithFormat:@"The shared Bawan window must retain ordinary ordering %@: level=%ld behavior=%lu",
            stage, static_cast<long>(window.level), static_cast<unsigned long>(window.collectionBehavior)]);
}

static NSRect FrameInRoot(NSView *view) {
    return [view convertRect:view.bounds toView:view.window.contentView];
}

static void CheckBounds(NSWindow *window) {
    Settle(window);
    NSView *root = window.contentView;
    Require(!root.hasAmbiguousLayout, @"Settings layout is ambiguous");
    NSScrollView *scroll = (NSScrollView *)FindView(root, @"settings-scroll");
    NSView *document = FindView(root, @"settings-document");
    Require([scroll isKindOfClass:NSScrollView.class] && document != nil && scroll.documentView == document &&
        scroll.hasVerticalScroller && !scroll.hasHorizontalScroller && !document.hasAmbiguousLayout,
        @"Settings must host one vertically scrollable document in the shared window");
    for (NSString *identifier in @[@"shortcut-selection-enabled", @"shortcut-selection-key", @"shortcut-selection-count",
            @"shortcut-selection-reset", @"shortcut-selection-status", @"shortcut-selection-permission",
            @"shortcut-panel-enabled", @"shortcut-panel-key", @"shortcut-panel-count", @"shortcut-panel-reset",
            @"shortcut-panel-status", @"shortcut-panel-permission", @"shortcut-reservation", @"shortcut-help",
            @"shortcut-selection-card", @"shortcut-panel-card", @"settings-model-status",
            @"settings-model-license", @"settings-model-setup", @"settings-model-message", @"settings-model-progress",
            @"shortcut-feedback", @"launch-at-login", @"login-items", @"login-hint",
            @"local-processing", @"shortcut-group", @"login-group", @"settings-header", @"settings-mascot",
            @"settings-close", @"settings-footer", @"settings-back", @"settings-scroll"]) {
        NSView *view = FindView(root, identifier);
        Require(view != nil, [@"Missing settings view: " stringByAppendingString:identifier]);
        if (view.hidden) continue;
        NSView *container = [view isDescendantOf:document] ? document : root;
        NSRect frame = [view convertRect:view.bounds toView:container];
        Require(frame.size.width > 0 && frame.size.height > 0 &&
                NSContainsRect(NSInsetRect(container.bounds, -0.5, -0.5), frame),
                [NSString stringWithFormat:@"Settings view clipped: %@ %@ in %@", identifier,
                    NSStringFromRect(frame), NSStringFromRect(container.bounds)]);
    }
    // Settings reuses the translator's chrome: the same masthead, medallion, trailing
    // icon slot and footer metrics, so switching pages never shifts the frame.
    NSView *header = FindView(root, @"settings-header");
    NSView *mascot = FindView(root, @"settings-mascot");
    NSView *close = FindView(root, @"settings-close");
    NSView *footer = FindView(root, @"settings-footer");
    NSView *back = FindView(root, @"settings-back");
    NSRect mascotFrame = [mascot convertRect:mascot.bounds toView:header];
    NSRect closeFrame = [close convertRect:close.bounds toView:header];
    NSRect backFrame = [back convertRect:back.bounds toView:footer];
    Require(FindView(root, @"settings-brand-name") == nil && FindView(root, @"settings-subtitle") == nil,
        @"The Settings header must match the translator's, without a wordmark or title");
    Require(std::abs(header.bounds.size.height - BawanHeaderHeight) < 1 &&
            std::abs(mascot.bounds.size.width - BawanBrandMarkSize) < 1 &&
            std::abs(mascot.bounds.size.height - BawanBrandMarkSize) < 1 &&
            std::abs(NSMidX(mascotFrame) - NSMidX(header.bounds)) < 1 &&
            std::abs(NSMidY(mascotFrame) - NSMidY(header.bounds)) < 1 &&
            std::abs(NSMaxX(header.bounds) - NSMaxX(closeFrame) - BawanChromeInset) < 1 &&
            std::abs(NSMidY(closeFrame) - NSMidY(header.bounds)) < 1,
            [NSString stringWithFormat:@"The Settings masthead must match the translator's: header=%@ mascot=%@ close=%@",
                NSStringFromRect(header.bounds), NSStringFromRect(mascotFrame), NSStringFromRect(closeFrame)]);
    Require(std::abs(footer.bounds.size.height - BawanFooterHeight) < 1 &&
            std::abs(NSMinX(backFrame) - BawanChromeInset) < 1 &&
            std::abs(backFrame.size.width - BawanFooterPrimaryWidth) < 1 &&
            std::abs(backFrame.size.height - BawanFooterButtonHeight) < 1 &&
            std::abs(NSMaxY(FrameInRoot(footer)) - NSMaxY(root.bounds)) < 1,
            [NSString stringWithFormat:@"Settings must use the translator's footer and primary button slot: footer=%@ back=%@",
                NSStringFromRect(footer.bounds), NSStringFromRect(backFrame)]);
    for (NSString *identifier in @[@"shortcut-selection-key", @"shortcut-panel-key", @"shortcut-selection-count",
                                   @"shortcut-panel-count"]) {
        NSControl *control = (NSControl *)FindView(root, identifier);
        Require(std::abs(control.bounds.size.height - 28) < 1 &&
                std::abs(control.font.pointSize - 13) < 0.1,
                @"Key recorders and press counts must use 28pt inputs and 13pt type");
    }
    NSView *selectionCard = FindView(root, @"shortcut-selection-card");
    NSView *panelCard = FindView(root, @"shortcut-panel-card");
    NSRect selectionFrame = FrameInRoot(selectionCard);
    NSRect panelFrame = FrameInRoot(panelCard);
    Require(!NSIntersectsRect(selectionFrame, panelFrame) &&
        std::abs(selectionFrame.size.width - panelFrame.size.width) < 1 &&
        std::abs(selectionFrame.size.height - panelFrame.size.height) < 1 &&
        std::abs(NSMinY(selectionFrame) - NSMinY(panelFrame)) < 1,
        @"The two shortcut capabilities must occupy equal side-by-side cards without overlap");
    for (NSString *prefix in @[@"selection", @"panel"]) {
        NSView *card = FindView(root, [NSString stringWithFormat:@"shortcut-%@-card", prefix]);
        NSButton *enabled = (NSButton *)FindView(root, [NSString stringWithFormat:@"shortcut-%@-enabled", prefix]);
        NSView *status = FindView(root, [NSString stringWithFormat:@"shortcut-%@-status", prefix]);
        NSView *permission = FindView(root, [NSString stringWithFormat:@"shortcut-%@-permission", prefix]);
        Require([enabled isKindOfClass:NSButton.class] && [enabled.title isEqualToString:@"Use shortcut"] &&
            [status isDescendantOf:card] && [permission isDescendantOf:card],
            @"Preference, readiness, and permission action must be grouped within their own capability");
    }
    Require(FindView(root, @"settings-sidebar") == nil && FindView(root, @"settings-tabs") == nil,
        @"Everyday settings must have no tabs or sidebar");
    NSView *shortcut = FindView(root, @"shortcut-group");
    NSView *login = FindView(root, @"login-group");
    NSView *privacy = FindView(root, @"local-processing");
    Require(!NSIntersectsRect(FrameInRoot(shortcut), FrameInRoot(login)) &&
            !NSIntersectsRect(FrameInRoot(login), FrameInRoot(privacy)),
            @"Settings groups and privacy footer must not overlap");
}

static NSEvent *KeyEvent(NSWindow *window, NSString *characters,
                         NSEventModifierFlags modifiers, unsigned short keyCode) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:modifiers timestamp:NSProcessInfo.processInfo.systemUptime
        windowNumber:window.windowNumber context:nil characters:characters
        charactersIgnoringModifiers:characters isARepeat:NO keyCode:keyCode];
}

// colorAtX: labels display components as Generic RGB. Retain the capture's ICC
// color space when rebuilding the sample before converting it for comparison.
static NSColor *BitmapColor(NSBitmapImageRep *bitmap, NSInteger x, NSInteger y) {
    NSColor *pixel = [bitmap colorAtX:x y:y];
    NSColorSpace *space = bitmap.colorSpace;
    Require(pixel != nil && space.colorSpaceModel == NSColorSpaceModelRGB,
            [NSString stringWithFormat:@"Expected an RGB capture with a color profile: %@", space]);
    CGFloat components[] = {pixel.redComponent, pixel.greenComponent, pixel.blueComponent, pixel.alphaComponent};
    return [NSColor colorWithColorSpace:space components:components count:4];
}

static CGFloat BackgroundBrightness(NSWindow *window) {
    Settle(window);
    NSView *root = window.contentView;
    NSBitmapImageRep *bitmap = [root bitmapImageRepForCachingDisplayInRect:root.bounds];
    Require(bitmap != nil, @"Could not capture the settings theme");
    [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [root cacheDisplayInRect:root.bounds toBitmapImageRep:bitmap];
    }];
    NSInteger x = static_cast<NSInteger>(8 * bitmap.pixelsWide / root.bounds.size.width);
    NSColor *color = [BitmapColor(bitmap, x, bitmap.pixelsHigh / 2) colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    Require(color != nil, @"Could not read the settings background");
    return color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722;
}

static void Capture(NSWindow *window, NSString *name) {
    CheckBounds(window);
    NSView *root = window.contentView;
    NSBitmapImageRep *bitmap = [root bitmapImageRepForCachingDisplayInRect:root.bounds];
    Require(bitmap != nil, @"Could not allocate settings capture");
    [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [root cacheDisplayInRect:root.bounds toBitmapImageRep:bitmap];
    }];
    // The window draws its background separately from contentView; preserve
    // that background beneath the captured view's transparent pixels.
    NSBitmapImageRep *composite = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil
        pixelsWide:bitmap.pixelsWide pixelsHigh:bitmap.pixelsHigh bitsPerSample:8 samplesPerPixel:4
        hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    // Composite in the capture's own color space. Converting to Generic RGB here
    // shifted saved colors, so Settings captures no longer matched the other pages.
    composite = [composite bitmapImageRepByRetaggingWithColorSpace:bitmap.colorSpace];
    composite.size = root.bounds.size;
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:composite]];
    [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [window.backgroundColor setFill];
        NSRectFill(root.bounds);
        NSImage *viewImage = [[NSImage alloc] initWithSize:root.bounds.size];
        [viewImage addRepresentation:bitmap];
        [viewImage drawInRect:root.bounds fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver fraction:1];
    }];
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [composite representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *path = [@"settings-smoke" stringByAppendingPathComponent:[name stringByAppendingString:@".png"]];
    Require([png writeToFile:path atomically:YES], @"Could not save settings capture");
}

static void RequireTint(NSWindow *window, NSColor *actual, NSColor *expected, NSString *message) {
    [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
        NSColor *a = [actual colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        NSColor *b = [expected colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        Require(a != nil && b != nil && std::abs(a.redComponent - b.redComponent) < 0.01 &&
                std::abs(a.greenComponent - b.greenComponent) < 0.01 &&
                std::abs(a.blueComponent - b.blueComponent) < 0.01,
                [NSString stringWithFormat:
                    @"%@; appearance=%@ actual-sRGB=%@ expected-sRGB=%@ original-actual=%@ original-expected=%@",
                    message, window.effectiveAppearance.name, a, b, actual, expected]);
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

static void CheckInputFaces(NSWindow *window) {
    NSAppearance *previous = window.appearance;
    for (NSAppearanceName appearance in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
        window.appearance = [NSAppearance appearanceNamed:appearance];
        Settle(window);
        for (NSString *identifier in @[@"shortcut-selection-key", @"shortcut-panel-key", @"shortcut-selection-count",
                                       @"shortcut-panel-count"]) {
            NSView *control = FindView(window.contentView, identifier);
            NSBitmapImageRep *bitmap = [control bitmapImageRepForCachingDisplayInRect:control.bounds];
            Require(bitmap != nil, @"Could not capture a shortcut input face");
            [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
                [control cacheDisplayInRect:control.bounds toBitmapImageRep:bitmap];
            }];
            NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            NSString *path = [@"settings-smoke" stringByAppendingPathComponent:
                [NSString stringWithFormat:@"input-%@-%@.png", identifier, appearance]];
            Require([png writeToFile:path atomically:YES], @"Could not save the shortcut input diagnostic");
            NSInteger y = static_cast<NSInteger>(4 * bitmap.pixelsHigh / control.bounds.size.height);
            RequireTint(window, BitmapColor(bitmap, bitmap.pixelsWide / 2, y), BawanColor(BawanBackground),
                [NSString stringWithFormat:@"Native cells must preserve Bawan's shared input face: %@; bitmapColorSpace=%@",
                    identifier, bitmap.colorSpace]);
        }
    }
    window.appearance = previous;
}

static NSString *TextInView(NSView *view) {
    NSMutableString *text = [NSMutableString string];
    if ([view isKindOfClass:NSTextField.class]) [text appendString:((NSTextField *)view).stringValue];
    for (NSView *child in view.subviews) [text appendFormat:@"\n%@", TextInView(child)];
    return text;
}

static void CheckLegacyPaper(NSWindow *window, NSScrollView *scroll) {
    NSScrollerStyle previousStyle = scroll.scrollerStyle;
    BOOL previousAutohide = scroll.autohidesScrollers;
    NSAppearance *previousAppearance = window.appearance;
    scroll.scrollerStyle = NSScrollerStyleLegacy;
    scroll.autohidesScrollers = NO;
    for (NSUInteger dark = 0; dark < 2; ++dark) {
        window.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        Settle(window);
        NSClipView *clip = scroll.contentView;
        Require(scroll.drawsBackground && clip.drawsBackground && !scroll.verticalScroller.hidden,
            @"The always-visible native scroller must retain the paper-backed scroll and clip surfaces");
        RequireTint(window, scroll.backgroundColor, BawanColor(BawanBackground),
            @"The legacy scroll gutter must resolve the current paper color");
        RequireTint(window, clip.backgroundColor, BawanColor(BawanBackground),
            @"The clip background must resolve the same paper color");
        NSBitmapImageRep *bitmap = [clip bitmapImageRepForCachingDisplayInRect:clip.bounds];
        Require(bitmap != nil, @"Could not capture the legacy scroll background");
        [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
            [clip cacheDisplayInRect:clip.bounds toBitmapImageRep:bitmap];
            NSInteger x = static_cast<NSInteger>(4 * bitmap.pixelsWide / clip.bounds.size.width);
            NSColor *actual = [BitmapColor(bitmap, x, bitmap.pixelsHigh / 2) colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            NSColor *expected = [BawanColor(BawanBackground) colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            Require(actual != nil && expected != nil &&
                std::abs(actual.redComponent - expected.redComponent) < 0.04 &&
                std::abs(actual.greenComponent - expected.greenComponent) < 0.04 &&
                std::abs(actual.blueComponent - expected.blueComponent) < 0.04,
                [NSString stringWithFormat:@"The rendered clip margin must stay paper-cobawand: actual=%@ expected=%@ profile=%@",
                    actual, expected, bitmap.colorSpace]);
        }];
        NSScroller *scroller = scroll.verticalScroller;
        NSBitmapImageRep *scrollerBitmap = [scroller bitmapImageRepForCachingDisplayInRect:scroller.bounds];
        Require(scrollerBitmap != nil, @"Could not capture the native legacy scroller");
        [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
            [scroller cacheDisplayInRect:scroller.bounds toBitmapImageRep:scrollerBitmap];
        }];
        NSData *slotPNG = [scrollerBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSString *slotPath = [NSString stringWithFormat:@"settings-smoke/legacy-slot-%@.png", dark ? @"dark" : @"light"];
        Require([slotPNG writeToFile:slotPath atomically:YES], @"Could not save the actual legacy scroller capture");
        NSRect slot = NSInsetRect(NSIntersectionRect(scroller.bounds, [scroller rectForPart:NSScrollerKnobSlot]), 1, 1);
        NSRect knob = [scroller rectForPart:NSScrollerKnob];
        NSRect blank = slot;
        if (!NSIsEmptyRect(knob)) {
            NSRect blocked = NSIntersectionRect(slot, NSInsetRect(knob, -1, -1));
            NSRect candidates[] = {
                NSMakeRect(NSMinX(slot), NSMinY(slot), slot.size.width, NSMinY(blocked) - NSMinY(slot)),
                NSMakeRect(NSMinX(slot), NSMaxY(blocked), slot.size.width, NSMaxY(slot) - NSMaxY(blocked)),
                NSMakeRect(NSMinX(slot), NSMinY(slot), NSMinX(blocked) - NSMinX(slot), slot.size.height),
                NSMakeRect(NSMaxX(blocked), NSMinY(slot), NSMaxX(slot) - NSMaxX(blocked), slot.size.height)
            };
            blank = NSZeroRect;
            for (NSRect candidate : candidates) {
                if (candidate.size.width >= 2 && candidate.size.height >= 2 &&
                    candidate.size.width * candidate.size.height > blank.size.width * blank.size.height) blank = candidate;
            }
        }
        Require(blank.size.width >= 2 && blank.size.height >= 2,
            [NSString stringWithFormat:@"The scroller fixture must expose a blank slot away from its knob: slot=%@ knob=%@ bounds=%@",
                NSStringFromRect(slot), NSStringFromRect(knob), NSStringFromRect(scroller.bounds)]);
        NSRect sampleRect = NSMakeRect(NSMidX(blank) - 1, NSMidY(blank) - 1, 2, 2);
        NSBitmapImageRep *sample = [scroller bitmapImageRepForCachingDisplayInRect:sampleRect];
        Require(sample != nil, @"Could not capture the empty legacy slot sample");
        [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
            [scroller cacheDisplayInRect:sampleRect toBitmapImageRep:sample];
            RequireTint(window, BitmapColor(sample, sample.pixelsWide / 2, sample.pixelsHigh / 2), BawanColor(BawanBackground),
                [NSString stringWithFormat:@"The actual native scroller slot must be paper-cobawand: slot=%@ knob=%@ sample=%@ profile=%@",
                    NSStringFromRect(slot), NSStringFromRect(knob), NSStringFromRect(sampleRect), sample.colorSpace]);
        }];
        Capture(window, dark ? @"legacy-scroller-dark" : @"legacy-scroller-light");
    }
    scroll.scrollerStyle = previousStyle;
    scroll.autohidesScrollers = previousAutohide;
    window.appearance = previousAppearance;
}

static void SendKey(SmokeSettingsViewController *settings, NSWindow *window, unsigned short code,
                    NSEventModifierFlags modifiers, BOOL down, NSString *characters) {
    [settings setRecordedKey:code down:down];
    NSEvent *event = [NSEvent keyEventWithType:down ? NSEventTypeKeyDown : NSEventTypeKeyUp
        location:NSZeroPoint modifierFlags:modifiers timestamp:NSProcessInfo.processInfo.systemUptime
        windowNumber:window.windowNumber context:nil characters:characters
        charactersIgnoringModifiers:characters isARepeat:NO keyCode:code];
    [NSApp sendEvent:event];
}

static void SendControlAction(NSControl *control) {
    [NSApp sendAction:control.action to:control.target from:control];
}

static void RunSmoke(void) {
    [NSFileManager.defaultManager createDirectoryAtPath:@"settings-smoke"
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *suite = [@"local.bawan.settings-smoke." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removePersistentDomainForName:suite];
    ShortcutPreferences *preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
    SmokeShortcutMonitor *monitor = [[SmokeShortcutMonitor alloc] initWithPreferences:preferences];
    SmokeSettingsViewController *settings = [[SmokeSettingsViewController alloc] initWithPreferences:preferences monitor:monitor];
    [settings setModelPhase:BawanModelSetupReady message:@"Ready" progress:1];
    TranslationPanel *panel = [[TranslationPanel alloc] init];
    __block NSUInteger translations = 0, cancellations = 0, closes = 0;
    panel.onTranslate = ^(NSString *__unused text, bawan::Direction __unused direction) { ++translations; };
    panel.onCancel = ^{ ++cancellations; };
    panel.onClose = ^{ ++closes; };
    __weak TranslationPanel *weakPanel = panel;
    __weak SettingsViewController *weakSettings = settings;
    panel.onSettings = ^{ [weakPanel showSettings:weakSettings]; };
    [panel showForManualInput];
    NSWindow *window = nil;
    for (NSWindow *candidate in NSApp.windows) {
        if ([candidate.contentView.identifier isEqualToString:@"bawan-panel"]) window = candidate;
    }
    Require(window != nil, @"The translator must provide the only settings host window");
    RequireOrdinaryWindow(window, @"after manual entry");
    NSView *translationRoot = window.contentView;
    NSTextView *source = (NSTextView *)FindView(translationRoot, @"source");
    NSTextView *output = (NSTextView *)FindView(translationRoot, @"output");
    NSButton *gear = (NSButton *)FindView(translationRoot, @"settings");
    NSString *original = @"The meeting has been moved to next Monday.";
    [panel showForSelection:original];
    RequireOrdinaryWindow(window, @"after selection entry");
    [panel showForManualInput];
    [panel setAvailable:YES busy:NO status:@"" kind:BawanStatusInformation];
    [source.undoManager beginUndoGrouping];
    [source insertText:@" Please review the document." replacementRange:NSMakeRange(source.string.length, 0)];
    [source.undoManager endUndoGrouping];
    NSString *edited = [source.string copy];
    Require(![edited isEqualToString:original] && source.undoManager.canUndo,
        @"The navigation fixture must establish a real editable undo operation");
    [source setSelectedRange:NSMakeRange(4, 7)];
    NSRange selection = source.selectedRange;
    [panel setOutput:@"会議は来週の月曜日に変更されました。" direction:bawan::Direction::EnglishToJapanese];
    [(NSButton *)FindView(translationRoot, @"copy") performClick:nil];
    NSRect hostFrame = window.frame;
    [gear performClick:nil];
    Settle(window);
    RequireOrdinaryWindow(window, @"after entering Settings");
    Require(window.contentView == settings.view && settings.view.window == window &&
        translationRoot.window == nil && NSEqualRects(window.frame, hostFrame),
        @"Settings must replace the existing window content without another window or resize");
    NSUInteger ownedWindows = 0;
    for (NSWindow *candidate in NSApp.windows) {
        NSString *identifier = candidate.contentView.identifier;
        if ([identifier isEqualToString:@"bawan-panel"] || [identifier isEqualToString:@"bawan-settings"]) ++ownedWindows;
    }
    Require(ownedWindows == 1, @"Settings must not create a second Bawan window");
    NSButton *back = (NSButton *)FindView(settings.view, @"settings-back");
    Capture(window, @"entry");
    CheckFrameDragging(window);
    Require(window.firstResponder == back,
        [NSString stringWithFormat:@"Entering Settings must focus Back rather than the detached translation editor: %@",
            window.firstResponder]);
    for (NSUInteger step = 0; step < 12; ++step) {
        [window selectNextKeyView:nil];
        NSResponder *responder = window.firstResponder;
        Require([responder isKindOfClass:NSView.class] &&
            [(NSView *)responder isDescendantOf:settings.view],
            [NSString stringWithFormat:@"Tab navigation must remain in the visible Settings screen: %@", responder]);
    }
    Require(window.undoManager == nil, @"Settings must not expose the hidden translator's undo manager");
    [window makeFirstResponder:window];
    [NSApp sendAction:@selector(undo:) to:nil from:window];
    Require([source.string isEqualToString:edited], @"Edit Undo in Settings must not change the hidden source");
    [NSApp sendAction:@selector(redo:) to:nil from:window];
    Require([source.string isEqualToString:edited], @"Edit Redo in Settings must not change the hidden source");
    [window performKeyEquivalent:KeyEvent(window, @"\r", NSEventModifierFlagCommand, 36)];
    NSInteger pasteboardCount = NSPasteboard.generalPasteboard.changeCount;
    [window performKeyEquivalent:KeyEvent(window, @"C", NSEventModifierFlagCommand | NSEventModifierFlagShift, 8)];
    Require(translations == 0 && cancellations == 0 && NSPasteboard.generalPasteboard.changeCount == pasteboardCount,
        @"Settings must not translate or copy the hidden translator through local shortcuts");
    [back performClick:nil];
    Require(window.contentView == translationRoot && NSEqualRects(window.frame, hostFrame) &&
        window.firstResponder == source && [source.string isEqualToString:edited] &&
        NSEqualRanges(source.selectedRange, selection) &&
        [[(NSButton *)FindView(translationRoot, @"copy") title] isEqualToString:@"Copied"] && closes == 0,
        @"Back must preserve text, selection, focus, copy feedback and the live host window");
    [source.undoManager undo];
    Require([source.string isEqualToString:original], @"The source edit must remain undoable after returning from Settings");
    [source.undoManager redo];
    Require([source.string isEqualToString:edited], @"Navigation must preserve the redo history too");
    [panel setAvailable:YES busy:YES status:@"Translating…" kind:BawanStatusInformation];
    [gear performClick:nil];
    [panel setOutput:@"Hidden streaming update" direction:bawan::Direction::EnglishToJapanese];
    [back performClick:nil];
    Require([output.string isEqualToString:@"Hidden streaming update"] &&
        [[(NSButton *)FindView(translationRoot, @"translate") title] isEqualToString:@"Cancel  ⌘↵"] &&
        cancellations == 0 && closes == 0,
        @"Settings navigation must retain streaming updates without cancelling the translation");
    [panel setAvailable:YES busy:NO status:@"" kind:BawanStatusInformation];
    [gear performClick:nil];
    CheckBounds(window);
    Require(BawanMascotImage() != nil && BawanPaperImage() != nil,
            @"Settings captures must load the real mascot and paper assets");
    NSView *root = window.contentView;
    NSSwitch *login = (NSSwitch *)FindView(root, @"launch-at-login");
    NSTextField *hint = (NSTextField *)FindView(root, @"login-hint");
    NSTextField *selectionStatus = (NSTextField *)FindView(root, @"shortcut-selection-status");
    NSTextField *panelStatus = (NSTextField *)FindView(root, @"shortcut-panel-status");
    NSTextField *feedback = (NSTextField *)FindView(root, @"shortcut-feedback");
    NSTextField *reservation = (NSTextField *)FindView(root, @"shortcut-reservation");
    NSButton *help = (NSButton *)FindView(root, @"shortcut-help");
    NSTextField *privacy = (NSTextField *)FindView(root, @"local-processing");
    NSButton *selectionEnabled = (NSButton *)FindView(root, @"shortcut-selection-enabled");
    NSButton *panelEnabled = (NSButton *)FindView(root, @"shortcut-panel-enabled");
    NSButton *selectionKey = (NSButton *)FindView(root, @"shortcut-selection-key");
    NSButton *panelKey = (NSButton *)FindView(root, @"shortcut-panel-key");
    NSPopUpButton *selectionCount = (NSPopUpButton *)FindView(root, @"shortcut-selection-count");
    NSString *privacyText = privacy.stringValue;
    Require(selectionEnabled.state == NSControlStateValueOn && panelEnabled.state == NSControlStateValueOn &&
        selectionCount.indexOfSelectedItem == 1 &&
        [selectionKey.title isEqualToString:ShortcutKeyLabel(bawan::defaultShortcuts()[0])] &&
        [panelKey.title isEqualToString:ShortcutKeyLabel(bawan::defaultShortcuts()[1])],
        @"Both shortcuts must show their enabled defaults and separate press counts");
    Require([selectionKey.toolTip containsString:@"Click"] &&
        selectionCount.accessibilityLabel.length > 0 && help != nil && window.attachedSheet == nil,
        @"Shortcut editing and press counts must stay labeled with optional help available");
    Require([privacy.stringValue containsString:@"do not affect typing or pasting"] && reservation.hidden,
        @"The settings footer must explain the manual fallback without a default-key reservation warning");
    [help performClick:nil];
    Settle(window);
    NSWindow *helpSheet = window.attachedSheet;
    NSString *helpText = helpSheet ? TextInView(helpSheet.contentView) : @"";
    Require(helpSheet != nil && [helpText containsString:@"Shortcut help"] &&
        [helpText containsString:@"400 ms"] && [helpText containsString:@"reserve their keys"] &&
        [helpText containsString:@"⌘Return"],
        [NSString stringWithFormat:@"Optional native help must reveal recording, reservation and translator-key details: sheet=%@ text=%@",
            helpSheet, helpText]);
    NSView *helpContent = helpSheet.contentView;
    NSBitmapImageRep *helpBitmap = [helpContent bitmapImageRepForCachingDisplayInRect:helpContent.bounds];
    Require(helpBitmap != nil, @"Could not capture optional shortcut help");
    [helpSheet.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [helpContent cacheDisplayInRect:helpContent.bounds toBitmapImageRep:helpBitmap];
    }];
    NSData *helpPNG = [helpBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    Require([helpPNG writeToFile:@"settings-smoke/shortcut-help.png" atomically:YES], @"Could not save optional help capture");
    [panel showForManualInput];
    NSDate *helpDeadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (window.attachedSheet && helpDeadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    Require(window.attachedSheet == nil && window.contentView == translationRoot,
        @"Opening the translator must dismiss Settings help without leaving an attached sheet");
    [gear performClick:nil];
    Require(window.contentView == root, @"Returning to Settings must reuse the screen after Help");
    __block NSUInteger loginSettings = 0, loginChanges = 0;
    __block BOOL requestedLogin = NO;
    settings.onLoginSettings = ^{ ++loginSettings; };
    settings.onLoginChanged = ^(BOOL enabled) { ++loginChanges; requestedLogin = enabled; };
    [(NSButton *)FindView(root, @"shortcut-selection-permission") performClick:nil];
    Require(monitor.permissionRequests == 1 && monitor.lastPermissionAction == bawan::ShortcutAction::TranslateSelection,
        @"Selection permission action must reach its own monitor action");
    [(NSButton *)FindView(root, @"shortcut-panel-permission") performClick:nil];
    Require(monitor.permissionRequests == 2 && monitor.lastPermissionAction == bawan::ShortcutAction::OpenPanel,
        @"Panel permission action must reach its own monitor action");
    NSButton *loginItems = (NSButton *)FindView(root, @"login-items");
    Require(loginItems.hidden, @"Normal login settings must not show a repair action");
    [settings setLoginStatus:SMAppServiceStatusRequiresApproval message:nil error:NO];
    Require(!loginItems.hidden, @"A pending login approval must expose its System Settings action");
    [loginItems performClick:nil];
    login.state = NSControlStateValueOn;
    SendControlAction(login);
    Require(loginSettings == 1 && loginChanges == 1 && requestedLogin,
        @"Login actions must forward exactly once without changing system services");

    [settings setLoginStatus:SMAppServiceStatusNotRegistered message:nil error:NO];
    Require(login.state == NSControlStateValueOff && hint.hidden && loginItems.hidden,
        @"Unregistered login service must show off without stale feedback or a repair action");
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    Require([selectionStatus.stringValue isEqualToString:@"Input Monitoring required"] &&
        [panelStatus.stringValue isEqualToString:@"Accessibility required"],
        @"Each shortcut must explain its own missing permission");
    RequireTintInBothAppearances(window, selectionStatus.textColor, BawanColor(BawanWarning),
        @"Input Monitoring permission must use the shared warning color");
    RequireTintInBothAppearances(window, panelStatus.textColor, BawanColor(BawanWarning),
        @"Accessibility permission must use the same warning color");
    NSTextField *modelStatus = (NSTextField *)FindView(root, @"settings-model-status");
    NSTextField *modelMessage = (NSTextField *)FindView(root, @"settings-model-message");
    NSButton *modelSetup = (NSButton *)FindView(root, @"settings-model-setup");
    NSProgressIndicator *modelProgress = (NSProgressIndicator *)FindView(root, @"settings-model-progress");
    __block NSUInteger modelLicenses = 0, modelSetups = 0;
    settings.onModelLicense = ^{ ++modelLicenses; };
    settings.onModelSetup = ^{ ++modelSetups; };
    [(NSButton *)FindView(root, @"settings-model-license") performClick:nil];
    Require(modelLicenses == 1 && [modelStatus.stringValue isEqualToString:@"Ready"] && modelSetup.hidden,
        @"Ready models must expose the license without showing a false retry action");
    [settings setModelPhase:BawanModelSetupNeedsDownload message:@"Prepare the local model first." progress:0];
    Require([modelStatus.stringValue isEqualToString:@"Not prepared"] && !modelSetup.hidden && modelProgress.hidden,
        @"An unprepared model must expose setup without claiming readiness");
    [modelSetup performClick:nil];
    Require(modelSetups == 1, @"The model setup action must reach its owner");
    [settings setModelPhase:BawanModelSetupPreparing message:@"Verifying the saved model…" progress:0.4];
    Require(!modelProgress.hidden && std::abs(modelProgress.doubleValue - 0.4) < 0.001 && modelSetup.hidden &&
        [modelMessage.stringValue containsString:@"Verifying"],
        @"Model preparation must show progress and its current message without allowing duplicate setup");
    [settings setModelPhase:BawanModelSetupPreparing message:@"Checking the local model…"
        progress:std::numeric_limits<double>::quiet_NaN()];
    Require(modelProgress.indeterminate && std::isfinite(modelProgress.doubleValue),
        @"Unknown model progress must remain a finite indeterminate presentation");
    [settings setModelPhase:BawanModelSetupPreparing message:@"Checking the local model…" progress:-1];
    Require(modelProgress.indeterminate && modelProgress.doubleValue == 0,
        @"A negative progress sentinel must not become a negative percentage");
    [settings setModelPhase:BawanModelSetupFailed message:@"The model could not be verified. Please try again." progress:0];
    Require(!modelSetup.hidden && [modelSetup.title isEqualToString:@"Retry"] && !modelMessage.hidden &&
        [modelStatus.stringValue isEqualToString:@"Needs attention"],
        @"Model setup failures must retain their message and expose Retry");
    [modelSetup performClick:nil];
    Require(modelSetups == 2, @"Retrying model setup must reach the same owner action");
    [settings setModelPhase:BawanModelSetupReady message:@"Ready" progress:1];
    Require(modelMessage.hidden && modelProgress.hidden && modelSetup.hidden,
        @"A recovered model must clear stale progress and error actions");
    bawan::ShortcutBinding panelBinding = [preferences bindingForAction:bawan::ShortcutAction::OpenPanel];
    auto disabledPanel = panelBinding;
    disabledPanel.enabled = false;
    Require([preferences setBinding:disabledPanel forAction:bawan::ShortcutAction::OpenPanel error:nil],
        @"The chosen design fixture must disable the window-opening shortcut");
    [settings refresh];
    NSScrollView *captureScroll = (NSScrollView *)FindView(root, @"settings-scroll");
    [captureScroll.contentView scrollToPoint:NSZeroPoint];
    [captureScroll reflectScrolledClipView:captureScroll.contentView];
    Capture(window, @"target-light");
    Require([preferences setBinding:panelBinding forAction:bawan::ShortcutAction::OpenPanel error:nil],
        @"The design fixture must restore the original window-opening preference");
    [settings refresh];
    Capture(window, @"light");
    CheckInputFaces(window);
    NSScrollView *scroll = (NSScrollView *)FindView(root, @"settings-scroll");
    NSView *document = FindView(root, @"settings-document");
    CGFloat baseHeight = document.bounds.size.height;
    NSRect settingsFrame = window.frame;
    [settings setLoginStatus:SMAppServiceStatusRequiresApproval message:nil error:NO];
    Require(login.state == NSControlStateValueOn && !hint.hidden && hint.stringValue.length > 0 && !loginItems.hidden,
        @"Pending approval must remain on with an explanatory message and repair action");
    Capture(window, @"approval");
    [settings setLoginStatus:SMAppServiceStatusEnabled message:nil error:NO];
    Require(login.state == NSControlStateValueOn && hint.hidden && loginItems.hidden,
        @"Enabled service must show on and clear approval feedback and repair actions");
    [panel showTranslation];
    monitor.permissionsGranted = YES;
    [panel showSettings:settings];
    // Hosted runners may withhold key-window focus. Drive the same real
    // delegate lifecycle used below rather than depending on window-server focus.
    [window.delegate windowDidBecomeKey:
        [NSNotification notificationWithName:NSWindowDidBecomeKeyNotification object:window]];
    Settle(window);
    monitor.permissionsGranted = NO;
    Require([selectionStatus.stringValue isEqualToString:@"Shortcut ready"] &&
        [panelStatus.stringValue isEqualToString:@"Shortcut ready"],
        @"Reopening Settings must replace stale permission warnings with the current ready state");
    Require(FindView(root, @"shortcut-selection-permission").hidden &&
        FindView(root, @"shortcut-panel-permission").hidden && reservation.hidden,
        @"Ready default shortcuts must hide local repair actions and reservation warnings");
    RequireTintInBothAppearances(window, selectionStatus.textColor, BawanColor(BawanSuccess),
        @"Ready shortcuts must use the shared success color");
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    Capture(window, @"dark");
    CGFloat darkBrightness = BackgroundBrightness(window);
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    Require(BackgroundBrightness(window) > darkBrightness + 0.3,
            @"Changing appearance on visible settings must repaint its paper background");
    monitor.panelAvailability = ShortcutAvailabilityFailed;
    [settings refresh];
    Require([panelStatus.stringValue isEqualToString:@"Could not start monitoring"] &&
        !FindView(root, @"shortcut-panel-permission").hidden,
        @"A failed shortcut needs its own status and retry action");
    RequireTintInBothAppearances(window, panelStatus.textColor, BawanColor(BawanError),
        @"Failed shortcuts must use the same error color as translation failures");
    monitor.panelAvailability = ShortcutAvailabilityAvailable;
    [settings refresh];

    [window setContentSize:NSMakeSize(640, 420)];
    Settle(window);
    [scroll.contentView scrollToPoint:NSZeroPoint];
    [scroll reflectScrolledClipView:scroll.contentView];
    CGFloat errorBaseHeight = document.bounds.size.height;
    NSRect errorFrame = window.frame;
    NSString *longError = @"Bawan could not change the launch-at-login setting. The operating system returned an error while updating this application’s registration. Open Login Items in System Settings, review the current permissions, and try again.\n\n"
        @"The registration response also includes details from the background-items service. The previous launch-at-login setting remains unchanged while the operation is incomplete. The application may need to be opened from a stable installation location before macOS can associate the registration with its current bundle.\n\n"
        @"After reviewing the system setting, return to Bawan and try the requested change again. If the operation still fails, retain the complete system message, including all nested error descriptions, when investigating the registration failure. This message is deliberately long so the same error must be revealed again after the user scrolls away from it.";
    [settings setLoginStatus:SMAppServiceStatusNotRegistered message:longError error:YES];
    CheckBounds(window);
    Require(login.state == NSControlStateValueOff && !hint.hidden && [hint.stringValue isEqualToString:longError] &&
        !loginItems.hidden, @"Failed changes must retain the actual state, full error and repair action");
    RequireTintInBothAppearances(window, hint.textColor, BawanColor(BawanError),
        @"Login failures must use the common error color");
    NSRect textBounds = [hint.attributedStringValue boundingRectWithSize:NSMakeSize(hint.bounds.size.width, CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading];
    Require(document.bounds.size.height > errorBaseHeight &&
        document.bounds.size.height > scroll.contentView.bounds.size.height &&
        hint.bounds.size.height + 2 >= textBounds.size.height && NSEqualRects(window.frame, errorFrame),
        @"Long login errors must grow a scrollable document while preserving the shared window frame");
    Require([privacy.stringValue isEqualToString:privacyText], @"Login feedback must preserve the privacy explanation");
    Capture(window, @"long-error");
    NSRect hintInDocument = [hint convertRect:hint.bounds toView:document];
    NSRect visibleDocument = scroll.documentVisibleRect;
    Require(NSContainsRect(NSInsetRect(visibleDocument, -0.5, -0.5), hintInDocument),
        [NSString stringWithFormat:@"The product must reveal the entire login error without test-side scrolling: hint=%@ visible=%@",
            NSStringFromRect(hintInDocument), NSStringFromRect(visibleDocument)]);
    [scroll.contentView scrollToPoint:NSZeroPoint];
    [scroll reflectScrolledClipView:scroll.contentView];
    Settle(window);
    Require(!NSContainsRect(scroll.documentVisibleRect, hintInDocument),
        @"The repeated-error fixture must first move away from the long login error");
    [settings setLoginStatus:SMAppServiceStatusNotRegistered message:longError error:YES];
    Settle(window);
    Require(NSContainsRect(NSInsetRect(scroll.documentVisibleRect, -0.5, -0.5), hintInDocument),
        @"Retrying the same failed operation must reveal its error again");
    [settings setLoginStatus:SMAppServiceStatusNotRegistered message:nil error:NO];
    [window setFrame:settingsFrame display:NO];
    Settle(window);
    Require(hint.hidden && document.bounds.size.height <= baseHeight + 1 && NSEqualRects(window.frame, settingsFrame),
        @"Clearing feedback must restore document height without resizing the shared window");
    [scroll.contentView scrollToPoint:NSZeroPoint];
    [scroll reflectScrolledClipView:scroll.contentView];
    [settings showError:@"The shortcut could not be saved because another action already uses this key."];
    Settle(window);
    NSRect feedbackInDocument = [feedback convertRect:feedback.bounds toView:document];
    Require(!feedback.hidden && NSContainsRect(NSInsetRect(scroll.documentVisibleRect, -0.5, -0.5), feedbackInDocument) &&
        NSEqualRects(window.frame, settingsFrame),
        @"A shortcut error must reveal its own feedback without resizing the shared window");
    Capture(window, @"shortcut-error");
    [settings showError:@""];

    selectionEnabled.state = NSControlStateValueOff;
    SendControlAction(selectionEnabled);
    Require(![preferences bindingForAction:bawan::ShortcutAction::TranslateSelection].enabled &&
        [preferences bindingForAction:bawan::ShortcutAction::OpenPanel].enabled &&
        [selectionStatus.stringValue isEqualToString:@"Off"], @"Disabling one action must preserve the other");
    RequireTintInBothAppearances(window, feedback.textColor, BawanColor(BawanSecondaryText),
        @"Saved settings must use informational feedback rather than error styling");
    [selectionCount selectItemAtIndex:0];
    SendControlAction(selectionCount);
    Require([preferences bindingForAction:bawan::ShortcutAction::TranslateSelection].pressCount == 1,
        @"A disabled action must still allow changing its press count");

    [panelKey performClick:nil];
    Require([selectionStatus.stringValue isEqualToString:@"Off"] &&
        [panelStatus.stringValue isEqualToString:@"Recording shortcut…"],
        @"Recording another shortcut must keep an independently disabled row Off");
    [panelKey performClick:nil];
    Require(!monitor.suspended && [panelStatus.stringValue isEqualToString:@"Shortcut ready"],
        @"Canceling an empty recording must restore the enabled row's ready status");

    [selectionKey performClick:nil];
    Require(monitor.suspended && !selectionEnabled.enabled, @"Recording must suspend global shortcuts");
    Require([selectionStatus.stringValue isEqualToString:@"Recording shortcut…"] &&
        [panelStatus.stringValue isEqualToString:@"Paused while recording"],
        @"Recording and paused rows must not claim that shortcuts are ready");
    RequireTintInBothAppearances(window, selectionStatus.textColor, BawanColor(BawanSecondaryText),
        @"Recording status must use neutral feedback rather than success green");
    RequireTintInBothAppearances(window, panelStatus.textColor, BawanColor(BawanSecondaryText),
        @"Paused shortcuts must use neutral feedback rather than success green");
    Capture(window, @"recording");
    SendKey(settings, window, 17, NSEventModifierFlagOption, YES, @"t");
    Require(monitor.suspended && [preferences bindingForAction:bawan::ShortcutAction::TranslateSelection].keyCode == 17,
        @"Recording must save the requested physical key but wait for its release");
    Require([selectionStatus.stringValue isEqualToString:@"Waiting for key release…"] &&
        [panelStatus.stringValue isEqualToString:@"Paused while recording"],
        @"Accepted held keys must show release waiting on the correct row");
    Capture(window, @"release-wait");
    SendKey(settings, window, 17, NSEventModifierFlagOption, NO, @"t");
    Require(!monitor.suspended && selectionEnabled.enabled, @"Key-up must safely restore monitoring");
    Require([selectionStatus.stringValue isEqualToString:@"Off"] &&
        [panelStatus.stringValue isEqualToString:@"Shortcut ready"],
        @"Key release must restore each row's actual enabled and ready state");
    selectionEnabled.state = NSControlStateValueOn;
    SendControlAction(selectionEnabled);
    Require(![preferences bindingForAction:bawan::ShortcutAction::TranslateSelection].enabled &&
        selectionEnabled.state == NSControlStateValueOff && !feedback.hidden,
        @"A conflicting single/double assignment must reject enabling without changing the old setting");

    [selectionKey performClick:nil];
    NSEventModifierFlags customModifiers = NSEventModifierFlagControl | NSEventModifierFlagOption;
    SendKey(settings, window, 40, customModifiers, YES, @"k");
    Require(monitor.suspended, @"An accepted key must remain suspended until release");
    SendKey(settings, window, 40, customModifiers, NO, @"k");
    selectionEnabled.state = NSControlStateValueOn;
    SendControlAction(selectionEnabled);
    bawan::ShortcutBinding custom = [preferences bindingForAction:bawan::ShortcutAction::TranslateSelection];
    Require(custom.enabled && custom.keyCode == 40 && custom.modifiers == (bawan::Control | bawan::Option) &&
        custom.pressCount == 1 && [selectionKey.title isEqualToString:ShortcutKeyLabel(custom)],
        @"Custom key, press count, enabled state, and visible label must agree");
    Require(!reservation.hidden && [reservation.stringValue containsString:@"reserve"],
        @"An enabled custom shortcut must explain that its key is reserved");
    ShortcutPreferences *reloaded = [[ShortcutPreferences alloc] initWithDefaults:defaults];
    bawan::ShortcutBinding persisted = [reloaded bindingForAction:bawan::ShortcutAction::TranslateSelection];
    Require(persisted.enabled && persisted.keyCode == custom.keyCode && persisted.modifiers == custom.modifiers &&
        persisted.pressCount == custom.pressCount, @"Recorded settings must survive reloading preferences");
    Capture(window, @"custom-shortcut");

    [selectionKey performClick:nil];
    SendKey(settings, window, 12, NSEventModifierFlagCommand, YES, @"q");
    SendKey(settings, window, 12, NSEventModifierFlagCommand, NO, @"q");
    Require(monitor.suspended && [preferences bindingForAction:bawan::ShortcutAction::TranslateSelection].keyCode == 40,
        @"Reserved commands must be consumed without quitting or replacing the old key");
    SendKey(settings, window, 53, 0, YES, @"\x1b");
    Require(monitor.suspended && window.visible, @"Esc cancels recording without closing or resuming before key-up");
    SendKey(settings, window, 53, 0, NO, @"\x1b");
    Require(!monitor.suspended && window.visible &&
        [preferences bindingForAction:bawan::ShortcutAction::TranslateSelection].keyCode == 40,
        @"Canceling recording must preserve the old assignment and the settings window");

    // Hosted runners can dispatch programmatic control actions without ever
    // granting this accessory app a key window. Exercise the real delegate's
    // focus lifecycle explicitly so orderOut is not an implicit prerequisite.
    id<NSWindowDelegate> delegate = window.delegate;
    [delegate windowDidBecomeKey:[NSNotification notificationWithName:NSWindowDidBecomeKeyNotification object:window]];
    Require(monitor.configurationActive, @"The become-key callback must mark settings active before focus-loss testing");
    [selectionKey performClick:nil];
    SendKey(settings, window, 0, 0, YES, @"a");
    Require(monitor.suspended, @"An invalid key keeps the recorder active");
    [window orderOut:nil];
    Settle(window);
    [delegate windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:window]];
    Require(monitor.suspended && !monitor.configurationActive,
        @"Focus loss must cancel recording but keep a swallowed held key suspended");
    [settings setRecordedKey:0 down:NO];
    NSDate *releaseDeadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (monitor.suspended && releaseDeadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    Require(!monitor.suspended, [NSString stringWithFormat:
        @"Physical release after focus loss must restore global monitoring (keyWindow=%@, configurationActive=%@, recorderEnabled=%@, feedback=%@)",
        @(window.keyWindow), @(monitor.configurationActive), @(selectionKey.enabled), feedback.stringValue]);
    [gear performClick:nil];
    [(NSButton *)FindView(root, @"shortcut-selection-reset") performClick:nil];
    bawan::ShortcutBinding restored = [preferences bindingForAction:bawan::ShortcutAction::TranslateSelection];
    Require(restored.enabled && bawan::isPassiveCopy(restored) && selectionCount.indexOfSelectedItem == 1,
        @"Reset restores the default key, press count, and enabled state");
    Require(reservation.hidden, @"Restoring the default assignments must remove the custom-key reservation warning");
    [settings showError:@""];
    [selectionKey performClick:nil];
    SendKey(settings, window, 0, 0, YES, @"a");
    [back performClick:nil];
    Require(window.contentView == translationRoot && !monitor.configurationActive && monitor.suspended && window.visible,
        @"Back during recording must leave Settings while retaining the held-key release guard");
    [settings setRecordedKey:0 down:NO];
    NSDate *backReleaseDeadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (monitor.suspended && backReleaseDeadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    Require(!monitor.suspended, @"Hidden Settings must finish physical-release cleanup after Back");
    [gear performClick:nil];
    [window setContentSize:NSMakeSize(640, 420)];
    CheckBounds(window);
    Capture(window, @"minimum");
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    Capture(window, @"minimum-dark");
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    CheckLegacyPaper(window, scroll);
    [window setFrame:settingsFrame display:NO];
    [back performClick:nil];
    Require(source.undoManager.canUndo, @"The prior passage must still have undo history before the selection boundary check");
    [gear performClick:nil];
    [panel showForSelection:@"A newly selected passage"];
    Require(window.contentView == translationRoot && [source.string isEqualToString:@"A newly selected passage"] &&
        !source.undoManager.canUndo && !monitor.configurationActive,
        @"A new selection from Settings must return to translation and clear the previous passage's undo history");
    [gear performClick:nil];
    [selectionKey interpretKeyEvents:@[KeyEvent(window, @"\x1b", 0, 53)]];
    Settle(window);
    Require(window.visible && window.contentView == translationRoot && closes == 0,
        @"Escape outside recording must return to translation without closing the shared window");
    [gear performClick:nil];
    [selectionKey performClick:nil];
    SendKey(settings, window, 0, 0, YES, @"a");
    [[window standardWindowButton:NSWindowCloseButton] performClick:nil];
    Require(!window.visible && closes == 1 && !monitor.configurationActive && monitor.suspended,
        @"The shared red close button must close once and retain held-key cleanup while recording");
    [settings setRecordedKey:0 down:NO];
    NSDate *closeReleaseDeadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (monitor.suspended && closeReleaseDeadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    Require(!monitor.suspended, @"Closing must eventually release the recorder's global suspension");
    [panel showForManualInput];
    [gear performClick:nil];
    Require([window performKeyEquivalent:KeyEvent(window, @"w", NSEventModifierFlagCommand, 13)] &&
        !window.visible && closes == 2 && !monitor.configurationActive,
        @"Command-W outside recording must close the same shared window exactly once");
    [defaults removePersistentDomainForName:suite];
    std::cout << "settings_smoke_complete=true\nshortcut_rows=2\nrecorder_release_and_cancel=true\ncaptures=settings-smoke\n";
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        __block int result = EXIT_FAILURE;
        [NSRunLoop.mainRunLoop performBlock:^{
            @try {
                try { RunSmoke(); result = EXIT_SUCCESS; }
                catch (const std::exception &error) { std::cerr << "Settings smoke failed: " << error.what() << '\n'; }
            } @catch (NSException *exception) {
                std::cerr << "Settings smoke failed: " << exception.reason.UTF8String << '\n';
            }
            [NSApp stop:nil];
            [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
                modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:0 context:nil
                subtype:0 data1:0 data2:0] atStart:NO];
        }];
        [NSApp run];
        return result;
    }
}
