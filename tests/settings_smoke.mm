#import "SettingsViewController.h"
#import "TranslationPanel.h"
#import <CoreGraphics/CoreGraphics.h>
#import "LoreAppearance.h"

#include <cstdlib>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <set>

@interface SmokeShortcutMonitor : ShortcutMonitor {
    ShortcutPreferences *_testPreferences;
    BOOL _testSuspended;
    BOOL _testSettingsActive;
}
@property(nonatomic) ShortcutAvailability selectionAvailability;
@property(nonatomic) ShortcutAvailability panelAvailability;
@property(nonatomic) NSUInteger permissionRequests;
@property(nonatomic) lore::ShortcutAction lastPermissionAction;
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
- (void)refresh {}
- (BOOL)suspended { return _testSuspended; }
- (void)setSuspended:(BOOL)value { _testSuspended = value; }
- (BOOL)settingsActive { return _testSettingsActive; }
- (void)setSettingsActive:(BOOL)value { _testSettingsActive = value; }
- (ShortcutAvailability)availabilityForAction:(lore::ShortcutAction)action {
    if (![_testPreferences bindingForAction:action].enabled) return ShortcutAvailabilityOff;
    return action == lore::ShortcutAction::TranslateSelection ? _selectionAvailability : _panelAvailability;
}
- (void)requestPermissionForAction:(lore::ShortcutAction)action {
    ++_permissionRequests;
    _lastPermissionAction = action;
}
@end

// Send events through NSApplication and its real local event monitor, while
// keeping physical release checks deterministic without injecting OS input.
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
            @"shortcut-panel-status", @"shortcut-panel-permission", @"shortcut-reservation", @"shortcut-permission-help",
            @"shortcut-key-heading", @"shortcut-presses-heading", @"shortcut-help",
            @"shortcut-feedback", @"launch-at-login", @"login-items", @"login-hint",
            @"local-processing", @"shortcut-group", @"login-group", @"settings-header", @"settings-mascot",
            @"settings-brand-name", @"settings-subtitle", @"settings-back", @"settings-scroll"]) {
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
    NSView *header = FindView(root, @"settings-header");
    NSView *mascot = FindView(root, @"settings-mascot");
    NSTextField *brand = (NSTextField *)FindView(root, @"settings-brand-name");
    NSView *subtitle = FindView(root, @"settings-subtitle");
    NSRect brandFrame = [brand convertRect:brand.bounds toView:header];
    NSRect mascotFrame = [mascot convertRect:mascot.bounds toView:header];
    // Anchors measure alignment rectangles; text-field frames include native ornament insets.
    NSRect brandAlignment = [brand.superview convertRect:[brand alignmentRectForFrame:brand.frame] toView:header];
    NSRect mascotAlignment = [mascot.superview convertRect:[mascot alignmentRectForFrame:mascot.frame] toView:header];
    CGFloat brandGap = NSMinX(brandAlignment) - NSMaxX(mascotAlignment);
    NSRect subtitleFrame = [subtitle convertRect:subtitle.bounds toView:header];
    NSView *back = FindView(root, @"settings-back");
    NSRect backFrame = [back convertRect:back.bounds toView:header];
    Require(std::abs(header.bounds.size.height - LoreHeaderHeight) < 1 &&
            std::abs(mascot.bounds.size.width - LoreBrandMarkSize) < 1 &&
            std::abs(mascot.bounds.size.height - LoreBrandMarkSize) < 1 &&
            std::abs(brand.font.pointSize - LoreBrandLogoSize) < 0.1 &&
            std::abs(NSMinX(mascotAlignment) - LoreBrandLeading) < 1 &&
            std::abs(brandGap - LoreBrandGap) < 1,
            [NSString stringWithFormat:
        @"Settings branding must use the shared geometry and typography: "
        @"headerHeight=%.2f expected=%.2f mascotBounds=%@ frame=%@ alignment=%@ expectedSize=%.2f "
        @"leading=%.2f expected=%.2f brandFrame=%@ alignment=%@ font=%.2f expected=%.2f gap=%.2f expected=%.2f",
        header.bounds.size.height, LoreHeaderHeight, NSStringFromRect(mascot.bounds),
        NSStringFromRect(mascotFrame), NSStringFromRect(mascotAlignment), LoreBrandMarkSize,
        NSMinX(mascotAlignment), LoreBrandLeading, NSStringFromRect(brandFrame), NSStringFromRect(brandAlignment),
        brand.font.pointSize, LoreBrandLogoSize, brandGap, LoreBrandGap]);
    Require(NSContainsRect(header.bounds, brandFrame) && NSContainsRect(header.bounds, subtitleFrame) &&
            NSContainsRect(header.bounds, backFrame) && !NSIntersectsRect(brandFrame, subtitleFrame) &&
            !NSIntersectsRect(brandFrame, mascotFrame) && !NSIntersectsRect(backFrame, brandFrame) &&
            !NSIntersectsRect(backFrame, subtitleFrame) && !NSIntersectsRect(backFrame, mascotFrame),
            @"Settings branding and Back must fit without overlapping each other");
    for (NSString *identifier in @[@"shortcut-selection-key", @"shortcut-panel-key", @"shortcut-selection-count",
                                   @"shortcut-panel-count"]) {
        NSControl *control = (NSControl *)FindView(root, identifier);
        Require(std::abs(control.bounds.size.height - LoreInputHeight) < 1 &&
                std::abs(control.font.pointSize - LoreInputFontSize) < 0.1,
                @"Key recorders and press counts must share the same input height and typography");
    }
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
            // Read empty vertical padding, clear of title glyphs, popup arrows and the border.
            NSInteger y = static_cast<NSInteger>(4 * bitmap.pixelsHigh / control.bounds.size.height);
            RequireTint(window, BitmapColor(bitmap, bitmap.pixelsWide / 2, y), LoreColor(LoreBackground),
                [NSString stringWithFormat:@"Native cells must preserve Lore's shared input face: %@; bitmapColorSpace=%@",
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
        RequireTint(window, scroll.backgroundColor, LoreColor(LoreBackground),
            @"The legacy scroll gutter must resolve the current paper color");
        RequireTint(window, clip.backgroundColor, LoreColor(LoreBackground),
            @"The clip background must resolve the same paper color");
        NSBitmapImageRep *bitmap = [clip bitmapImageRepForCachingDisplayInRect:clip.bounds];
        Require(bitmap != nil, @"Could not capture the legacy scroll background");
        [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
            [clip cacheDisplayInRect:clip.bounds toBitmapImageRep:bitmap];
            // The document's outer margin contains no text, card border or scroller glyph.
            NSInteger x = static_cast<NSInteger>(4 * bitmap.pixelsWide / clip.bounds.size.width);
            RequireTint(window, BitmapColor(bitmap, x, bitmap.pixelsHigh / 2), LoreColor(LoreBackground),
                [NSString stringWithFormat:@"The rendered clip margin must stay paper-colored; profile=%@", bitmap.colorSpace]);
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
    NSString *suite = [@"local.lore.settings-smoke." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removePersistentDomainForName:suite];
    ShortcutPreferences *preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
    SmokeShortcutMonitor *monitor = [[SmokeShortcutMonitor alloc] initWithPreferences:preferences];
    SmokeSettingsViewController *settings = [[SmokeSettingsViewController alloc] initWithPreferences:preferences monitor:monitor];
    TranslationPanel *panel = [[TranslationPanel alloc] init];
    __block NSUInteger translations = 0, cancellations = 0, closes = 0;
    panel.onTranslate = ^(NSString *__unused text, lore::Direction __unused direction) { ++translations; };
    panel.onCancel = ^{ ++cancellations; };
    panel.onClose = ^{ ++closes; };
    __weak TranslationPanel *weakPanel = panel;
    __weak SettingsViewController *weakSettings = settings;
    panel.onSettings = ^{ [weakPanel showSettings:weakSettings]; };
    [panel showForManualInput];
    NSWindow *window = nil;
    for (NSWindow *candidate in NSApp.windows) {
        if ([candidate.contentView.identifier isEqualToString:@"lore-panel"]) window = candidate;
    }
    Require(window != nil, @"The translator must provide the only settings host window");
    NSView *translationRoot = window.contentView;
    NSTextView *source = (NSTextView *)FindView(translationRoot, @"source");
    NSTextView *output = (NSTextView *)FindView(translationRoot, @"output");
    NSButton *gear = (NSButton *)FindView(translationRoot, @"settings");
    NSString *original = @"The meeting has been moved to next Monday.";
    [panel showForSelection:original];
    [panel showForManualInput];
    [panel setAvailable:YES busy:NO status:@"" kind:LoreStatusInformation];
    [source.undoManager beginUndoGrouping];
    [source insertText:@" Please review the document." replacementRange:NSMakeRange(source.string.length, 0)];
    [source.undoManager endUndoGrouping];
    NSString *edited = [source.string copy];
    Require(![edited isEqualToString:original] && source.undoManager.canUndo,
        @"The navigation fixture must establish a real editable undo operation");
    [source setSelectedRange:NSMakeRange(4, 7)];
    NSRange selection = source.selectedRange;
    [panel setOutput:@"会議は来週の月曜日に変更されました。" direction:lore::Direction::EnglishToJapanese];
    [(NSButton *)FindView(translationRoot, @"copy") performClick:nil];
    NSRect hostFrame = window.frame;
    [gear performClick:nil];
    Settle(window);
    Require(window.contentView == settings.view && settings.view.window == window &&
        translationRoot.window == nil && NSEqualRects(window.frame, hostFrame),
        @"Settings must replace the existing window content without another window or resize");
    NSUInteger ownedWindows = 0;
    for (NSWindow *candidate in NSApp.windows) {
        NSString *identifier = candidate.contentView.identifier;
        if ([identifier isEqualToString:@"lore-panel"] || [identifier isEqualToString:@"lore-settings"]) ++ownedWindows;
    }
    Require(ownedWindows == 1, @"Settings must not create a second Lore window");
    NSButton *back = (NSButton *)FindView(settings.view, @"settings-back");
    Require(window.firstResponder == back,
        @"Entering Settings must focus its Back control rather than the detached translation editor");
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
    [panel setAvailable:YES busy:YES status:@"Translating…" kind:LoreStatusInformation];
    [gear performClick:nil];
    [panel setOutput:@"Hidden streaming update" direction:lore::Direction::EnglishToJapanese];
    [back performClick:nil];
    Require([output.string isEqualToString:@"Hidden streaming update"] &&
        [[(NSButton *)FindView(translationRoot, @"translate") title] isEqualToString:@"Cancel  ⌘↵"] &&
        cancellations == 0 && closes == 0,
        @"Settings navigation must retain streaming updates without cancelling the translation");
    [panel setAvailable:YES busy:NO status:@"" kind:LoreStatusInformation];
    [gear performClick:nil];
    CheckBounds(window);
    Require(LoreMascotImage() != nil && LorePaperImage() != nil,
            @"Settings captures must load the real mascot and paper assets");
    NSView *root = window.contentView;
    NSSwitch *login = (NSSwitch *)FindView(root, @"launch-at-login");
    NSTextField *hint = (NSTextField *)FindView(root, @"login-hint");
    NSTextField *selectionStatus = (NSTextField *)FindView(root, @"shortcut-selection-status");
    NSTextField *panelStatus = (NSTextField *)FindView(root, @"shortcut-panel-status");
    NSTextField *feedback = (NSTextField *)FindView(root, @"shortcut-feedback");
    NSTextField *permissionHelp = (NSTextField *)FindView(root, @"shortcut-permission-help");
    NSTextField *reservation = (NSTextField *)FindView(root, @"shortcut-reservation");
    NSTextField *keyHeading = (NSTextField *)FindView(root, @"shortcut-key-heading");
    NSTextField *pressesHeading = (NSTextField *)FindView(root, @"shortcut-presses-heading");
    NSButton *help = (NSButton *)FindView(root, @"shortcut-help");
    NSTextField *privacy = (NSTextField *)FindView(root, @"local-processing");
    NSSwitch *selectionEnabled = (NSSwitch *)FindView(root, @"shortcut-selection-enabled");
    NSSwitch *panelEnabled = (NSSwitch *)FindView(root, @"shortcut-panel-enabled");
    NSButton *selectionKey = (NSButton *)FindView(root, @"shortcut-selection-key");
    NSButton *panelKey = (NSButton *)FindView(root, @"shortcut-panel-key");
    NSPopUpButton *selectionCount = (NSPopUpButton *)FindView(root, @"shortcut-selection-count");
    NSString *privacyText = privacy.stringValue;
    Require(selectionEnabled.state == NSControlStateValueOn && panelEnabled.state == NSControlStateValueOn &&
        selectionCount.indexOfSelectedItem == 1 &&
        [selectionKey.title isEqualToString:ShortcutKeyLabel(lore::defaultShortcuts()[0])] &&
        [panelKey.title isEqualToString:ShortcutKeyLabel(lore::defaultShortcuts()[1])],
        @"Both shortcuts must show their enabled defaults and separate press counts");
    Require([keyHeading.stringValue containsString:@"click"] &&
        [pressesHeading.stringValue isEqualToString:@"Presses"] && help != nil && window.attachedSheet == nil,
        @"Shortcut editing and press counts must be discoverable before opening optional help");
    Require(!permissionHelp.hidden && [permissionHelp.stringValue containsString:@"Typing and pasting"] && reservation.hidden,
        @"Missing permissions must explain the manual fallback without an irrelevant default-key reservation warning");
    [help performClick:nil];
    Settle(window);
    NSWindow *helpSheet = window.attachedSheet;
    NSString *helpText = helpSheet ? TextInView(helpSheet.contentView) : @"";
    Require(helpSheet != nil && [helpText containsString:@"Shortcut help"] &&
        [helpText containsString:@"400 ms"] && [helpText containsString:@"reserve their keys"] &&
        [helpText containsString:@"⌘Return"],
        @"Optional native help must reveal recording, reservation and translator-key details on demand");
    NSView *helpContent = helpSheet.contentView;
    NSBitmapImageRep *helpBitmap = [helpContent bitmapImageRepForCachingDisplayInRect:helpContent.bounds];
    Require(helpBitmap != nil, @"Could not capture optional shortcut help");
    [helpSheet.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [helpContent cacheDisplayInRect:helpContent.bounds toBitmapImageRep:helpBitmap];
    }];
    NSData *helpPNG = [helpBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    Require([helpPNG writeToFile:@"settings-smoke/shortcut-help.png" atomically:YES], @"Could not save optional help capture");
    [window endSheet:helpSheet returnCode:NSModalResponseOK];
    NSDate *helpDeadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (window.attachedSheet && helpDeadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    Require(window.attachedSheet == nil && window.contentView == root,
        @"Dismissing optional help must return to the existing Settings screen");
    __block NSUInteger loginSettings = 0, loginChanges = 0;
    __block BOOL requestedLogin = NO;
    settings.onLoginSettings = ^{ ++loginSettings; };
    settings.onLoginChanged = ^(BOOL enabled) { ++loginChanges; requestedLogin = enabled; };
    [(NSButton *)FindView(root, @"shortcut-selection-permission") performClick:nil];
    Require(monitor.permissionRequests == 1 && monitor.lastPermissionAction == lore::ShortcutAction::TranslateSelection,
        @"Selection permission action must reach its own monitor action");
    [(NSButton *)FindView(root, @"shortcut-panel-permission") performClick:nil];
    Require(monitor.permissionRequests == 2 && monitor.lastPermissionAction == lore::ShortcutAction::OpenPanel,
        @"Panel permission action must reach its own monitor action");
    [(NSButton *)FindView(root, @"login-items") performClick:nil];
    login.state = NSControlStateValueOn;
    SendControlAction(login);
    Require(loginSettings == 1 && loginChanges == 1 && requestedLogin,
        @"Login actions must forward exactly once without changing system services");

    [settings setLoginStatus:SMAppServiceStatusNotRegistered message:nil error:NO];
    Require(login.state == NSControlStateValueOff && hint.hidden,
        @"Unregistered login service must show off without a stale message");
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    Require([selectionStatus.stringValue isEqualToString:@"Input Monitoring required"] &&
        [panelStatus.stringValue isEqualToString:@"Accessibility required"],
        @"Each shortcut must explain its own missing permission");
    RequireTintInBothAppearances(window, selectionStatus.textColor, LoreColor(LoreWarning),
        @"Input Monitoring permission must use the shared warning color");
    RequireTintInBothAppearances(window, panelStatus.textColor, LoreColor(LoreWarning),
        @"Accessibility permission must use the same warning color");
    Capture(window, @"light");
    CheckInputFaces(window);
    NSScrollView *scroll = (NSScrollView *)FindView(root, @"settings-scroll");
    NSView *document = FindView(root, @"settings-document");
    CGFloat baseHeight = document.bounds.size.height;
    NSRect settingsFrame = window.frame;
    [settings setLoginStatus:SMAppServiceStatusRequiresApproval message:nil error:NO];
    Require(login.state == NSControlStateValueOn && !hint.hidden && hint.stringValue.length > 0,
        @"Pending approval must remain on with an explanatory message");
    Capture(window, @"approval");
    [settings setLoginStatus:SMAppServiceStatusEnabled message:nil error:NO];
    Require(login.state == NSControlStateValueOn && hint.hidden,
        @"Enabled service must show on and clear approval feedback");
    monitor.selectionAvailability = ShortcutAvailabilityAvailable;
    monitor.panelAvailability = ShortcutAvailabilityAvailable;
    [settings refresh];
    Require([selectionStatus.stringValue isEqualToString:@"Shortcut ready"] &&
        [panelStatus.stringValue isEqualToString:@"Shortcut ready"], @"Active shortcuts must show ready");
    Require(permissionHelp.hidden && reservation.hidden,
        @"Ready default shortcuts must remove setup-only explanations");
    RequireTintInBothAppearances(window, selectionStatus.textColor, LoreColor(LoreSuccess),
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
    RequireTintInBothAppearances(window, panelStatus.textColor, LoreColor(LoreError),
        @"Failed shortcuts must use the same error color as translation failures");
    monitor.panelAvailability = ShortcutAvailabilityAvailable;
    [settings refresh];

    [window setContentSize:NSMakeSize(640, 420)];
    Settle(window);
    [scroll.contentView scrollToPoint:NSZeroPoint];
    [scroll reflectScrolledClipView:scroll.contentView];
    CGFloat errorBaseHeight = document.bounds.size.height;
    NSRect errorFrame = window.frame;
    NSString *longError = @"Lore could not change the launch-at-login setting. The operating system returned an error while updating this application’s registration. Open Login Items in System Settings, review the current permissions, and try again.";
    [settings setLoginStatus:SMAppServiceStatusNotRegistered message:longError error:YES];
    CheckBounds(window);
    Require(login.state == NSControlStateValueOff && !hint.hidden && [hint.stringValue isEqualToString:longError],
        @"Failed changes must restore the actual login state and retain the full error");
    RequireTintInBothAppearances(window, hint.textColor, LoreColor(LoreError),
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
    Require(![preferences bindingForAction:lore::ShortcutAction::TranslateSelection].enabled &&
        [preferences bindingForAction:lore::ShortcutAction::OpenPanel].enabled &&
        [selectionStatus.stringValue isEqualToString:@"Off"], @"Disabling one action must preserve the other");
    RequireTintInBothAppearances(window, feedback.textColor, LoreColor(LoreSecondaryText),
        @"Saved settings must use informational feedback rather than error styling");
    [selectionCount selectItemAtIndex:0];
    SendControlAction(selectionCount);
    Require([preferences bindingForAction:lore::ShortcutAction::TranslateSelection].pressCount == 1,
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
    RequireTintInBothAppearances(window, selectionStatus.textColor, LoreColor(LoreSecondaryText),
        @"Recording status must use neutral feedback rather than success green");
    RequireTintInBothAppearances(window, panelStatus.textColor, LoreColor(LoreSecondaryText),
        @"Paused shortcuts must use neutral feedback rather than success green");
    Capture(window, @"recording");
    SendKey(settings, window, 17, NSEventModifierFlagOption, YES, @"t");
    Require(monitor.suspended && [preferences bindingForAction:lore::ShortcutAction::TranslateSelection].keyCode == 17,
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
    Require(![preferences bindingForAction:lore::ShortcutAction::TranslateSelection].enabled &&
        selectionEnabled.state == NSControlStateValueOff && !feedback.hidden,
        @"A conflicting single/double assignment must reject enabling without changing the old setting");

    [selectionKey performClick:nil];
    NSEventModifierFlags customModifiers = NSEventModifierFlagControl | NSEventModifierFlagOption;
    SendKey(settings, window, 40, customModifiers, YES, @"k");
    Require(monitor.suspended, @"An accepted key must remain suspended until release");
    SendKey(settings, window, 40, customModifiers, NO, @"k");
    selectionEnabled.state = NSControlStateValueOn;
    SendControlAction(selectionEnabled);
    lore::ShortcutBinding custom = [preferences bindingForAction:lore::ShortcutAction::TranslateSelection];
    Require(custom.enabled && custom.keyCode == 40 && custom.modifiers == (lore::Control | lore::Option) &&
        custom.pressCount == 1 && [selectionKey.title isEqualToString:ShortcutKeyLabel(custom)],
        @"Custom key, press count, enabled state, and visible label must agree");
    Require(!reservation.hidden && [reservation.stringValue containsString:@"reserve"],
        @"An enabled custom shortcut must explain that its key is reserved");
    ShortcutPreferences *reloaded = [[ShortcutPreferences alloc] initWithDefaults:defaults];
    lore::ShortcutBinding persisted = [reloaded bindingForAction:lore::ShortcutAction::TranslateSelection];
    Require(persisted.enabled && persisted.keyCode == custom.keyCode && persisted.modifiers == custom.modifiers &&
        persisted.pressCount == custom.pressCount, @"Recorded settings must survive reloading preferences");
    Capture(window, @"custom-shortcut");

    [selectionKey performClick:nil];
    SendKey(settings, window, 12, NSEventModifierFlagCommand, YES, @"q");
    SendKey(settings, window, 12, NSEventModifierFlagCommand, NO, @"q");
    Require(monitor.suspended && [preferences bindingForAction:lore::ShortcutAction::TranslateSelection].keyCode == 40,
        @"Reserved commands must be consumed without quitting or replacing the old key");
    SendKey(settings, window, 53, 0, YES, @"\x1b");
    Require(monitor.suspended && window.visible, @"Esc cancels recording without closing or resuming before key-up");
    SendKey(settings, window, 53, 0, NO, @"\x1b");
    Require(!monitor.suspended && window.visible &&
        [preferences bindingForAction:lore::ShortcutAction::TranslateSelection].keyCode == 40,
        @"Canceling recording must preserve the old assignment and the settings window");

    // Hosted runners can dispatch programmatic control actions without ever
    // granting this accessory app a key window. Exercise the real delegate's
    // focus lifecycle explicitly so orderOut is not an implicit prerequisite.
    id<NSWindowDelegate> delegate = window.delegate;
    [delegate windowDidBecomeKey:[NSNotification notificationWithName:NSWindowDidBecomeKeyNotification object:window]];
    Require(monitor.settingsActive, @"The become-key callback must mark settings active before focus-loss testing");
    [selectionKey performClick:nil];
    SendKey(settings, window, 0, 0, YES, @"a");
    Require(monitor.suspended, @"An invalid key keeps the recorder active");
    [window orderOut:nil];
    Settle(window);
    [delegate windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:window]];
    Require(monitor.suspended && !monitor.settingsActive,
        @"Focus loss must cancel recording but keep a swallowed held key suspended");
    [settings setRecordedKey:0 down:NO];
    NSDate *releaseDeadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (monitor.suspended && releaseDeadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    Require(!monitor.suspended, [NSString stringWithFormat:
        @"Physical release after focus loss must restore global monitoring (keyWindow=%@, settingsActive=%@, recorderEnabled=%@, feedback=%@)",
        @(window.keyWindow), @(monitor.settingsActive), @(selectionKey.enabled), feedback.stringValue]);
    [gear performClick:nil];
    [(NSButton *)FindView(root, @"shortcut-selection-reset") performClick:nil];
    lore::ShortcutBinding restored = [preferences bindingForAction:lore::ShortcutAction::TranslateSelection];
    Require(restored.enabled && lore::isPassiveCopy(restored) && selectionCount.indexOfSelectedItem == 1,
        @"Reset restores the default key, press count, and enabled state");
    Require(reservation.hidden, @"Restoring the default assignments must remove the custom-key reservation warning");
    [settings showError:@""];
    // Leaving the page does not resign the shared key window. It must still
    // finish recording and wait for a swallowed key's physical release.
    [selectionKey performClick:nil];
    SendKey(settings, window, 0, 0, YES, @"a");
    [back performClick:nil];
    Require(window.contentView == translationRoot && !monitor.settingsActive && monitor.suspended && window.visible,
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
    for (NSUInteger iteration = 0; iteration < 20; ++iteration) {
        [back performClick:nil];
        Require(window.contentView == translationRoot && !monitor.settingsActive,
            @"Returning to translation must deactivate Settings without changing windows");
        [gear performClick:nil];
        Require(settings.view == root && window.contentView == root && settings.view.window == window &&
            FindView(root, @"shortcut-selection-key") == selectionKey &&
            FindView(root, @"settings-scroll") == scroll && FindView(root, @"settings-document") == document &&
            FindView(root, @"shortcut-help") == help && window.attachedSheet == nil && NSEqualRects(window.frame, settingsFrame),
            @"Twenty navigation cycles must reuse the same host, controller view and shortcut controls");
        CheckBounds(window);
    }
    [back performClick:nil];
    Require(source.undoManager.canUndo, @"The prior passage must still have undo history before the selection boundary check");
    [gear performClick:nil];
    [panel showForSelection:@"A newly selected passage"];
    Require(window.contentView == translationRoot && [source.string isEqualToString:@"A newly selected passage"] &&
        !source.undoManager.canUndo && !monitor.settingsActive,
        @"A new selection from Settings must return to translation and clear the previous passage's undo history");
    [gear performClick:nil];
    // Exercise a real settings control's responder chain, including the view
    // controller, without depending on hosted CI granting a key window.
    [selectionKey interpretKeyEvents:@[KeyEvent(window, @"\x1b", 0, 53)]];
    Settle(window);
    Require(window.visible && window.contentView == translationRoot && closes == 0,
        @"Escape outside recording must return to translation without closing the shared window");
    [gear performClick:nil];
    [selectionKey performClick:nil];
    SendKey(settings, window, 0, 0, YES, @"a");
    [[window standardWindowButton:NSWindowCloseButton] performClick:nil];
    Require(!window.visible && closes == 1 && !monitor.settingsActive && monitor.suspended,
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
        !window.visible && closes == 2 && !monitor.settingsActive,
        @"Command-W outside recording must close the same shared window exactly once");
    [defaults removePersistentDomainForName:suite];
    std::cout << "settings_smoke_complete=true\nreused_navigation_cycles=20\nshortcut_rows=2\nrecorder_release_and_cancel=true\ncaptures=settings-smoke\n";
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
