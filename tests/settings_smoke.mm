#import "SettingsWindow.h"

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
    for (NSString *identifier in @[@"shortcut-status", @"input-monitoring", @"launch-at-login",
            @"login-items", @"login-hint", @"local-processing", @"shortcut-group", @"login-group"]) {
        NSView *view = FindView(root, identifier);
        Require(view != nil, [@"Missing settings view: " stringByAppendingString:identifier]);
        if (view.hidden) continue;
        NSRect frame = FrameInRoot(view);
        Require(frame.size.width > 0 && frame.size.height > 0 &&
                NSContainsRect(NSInsetRect(root.bounds, -0.5, -0.5), frame),
                [NSString stringWithFormat:@"Settings view clipped: %@ %@ in %@", identifier,
                    NSStringFromRect(frame), NSStringFromRect(root.bounds)]);
    }
    NSView *shortcut = FindView(root, @"shortcut-group");
    NSView *login = FindView(root, @"login-group");
    NSView *privacy = FindView(root, @"local-processing");
    Require(!NSIntersectsRect(FrameInRoot(shortcut), FrameInRoot(login)) &&
            !NSIntersectsRect(FrameInRoot(login), FrameInRoot(privacy)),
            @"Settings groups and privacy footer must not overlap");
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

static void RunSmoke(void) {
    [NSFileManager.defaultManager createDirectoryAtPath:@"settings-smoke"
        withIntermediateDirectories:YES attributes:nil error:nil];
    SettingsWindow *settings = [[SettingsWindow alloc] init];
    NSWindow *window = settings.window;
    [settings showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [window makeKeyAndOrderFront:nil];
    CheckBounds(window);
    NSView *root = window.contentView;
    NSSwitch *login = (NSSwitch *)FindView(root, @"launch-at-login");
    NSTextField *hint = (NSTextField *)FindView(root, @"login-hint");
    NSTextField *shortcut = (NSTextField *)FindView(root, @"shortcut-status");
    NSTextField *privacy = (NSTextField *)FindView(root, @"local-processing");
    NSString *privacyText = privacy.stringValue;
    __block NSUInteger permissions = 0, loginSettings = 0, loginChanges = 0;
    __block BOOL requestedLogin = NO;
    settings.onInputMonitoring = ^{ ++permissions; };
    settings.onLoginSettings = ^{ ++loginSettings; };
    settings.onLoginChanged = ^(BOOL enabled) { ++loginChanges; requestedLogin = enabled; };
    [(NSButton *)FindView(root, @"input-monitoring") performClick:nil];
    [(NSButton *)FindView(root, @"login-items") performClick:nil];
    login.state = NSControlStateValueOn;
    [NSApp sendAction:login.action to:login.target from:login];
    Require(permissions == 1 && loginSettings == 1 && loginChanges == 1 && requestedLogin,
            @"Settings actions must forward exactly once without changing system services");

    [settings setLoginStatus:SMAppServiceStatusNotRegistered message:nil error:NO];
    Require(login.state == NSControlStateValueOff && hint.hidden,
            @"Unregistered login service must show off without a stale message");
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    [settings setShortcutAvailable:NO permissionGranted:NO];
    Require([shortcut.stringValue isEqualToString:@"Input Monitoring required"],
            @"Missing Input Monitoring permission needs an accurate status");
    Capture(window, @"light");
    CGFloat baseHeight = root.bounds.size.height;
    [settings setLoginStatus:SMAppServiceStatusRequiresApproval message:nil error:NO];
    Require(login.state == NSControlStateValueOn && !hint.hidden && hint.stringValue.length > 0,
            @"Pending approval must remain on with an explanatory message");
    Capture(window, @"approval");
    [settings setLoginStatus:SMAppServiceStatusEnabled message:nil error:NO];
    Require(login.state == NSControlStateValueOn && hint.hidden,
            @"Enabled service must show on and clear approval feedback");
    [settings setShortcutAvailable:YES permissionGranted:YES];
    Require([shortcut.stringValue isEqualToString:@"Shortcut ready"], @"Active shortcut must show ready");
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    Capture(window, @"dark");
    [settings setShortcutAvailable:NO permissionGranted:YES];
    Require([shortcut.stringValue isEqualToString:@"Shortcut not active"],
            @"An inactive shortcut with permission must not be described as ready");

    NSString *longError = @"Lore could not change the launch-at-login setting. The operating system returned an error while updating this application’s registration. Open Login Items in System Settings, review the current permissions, and try again.";
    [settings setLoginStatus:SMAppServiceStatusNotRegistered message:longError error:YES];
    CheckBounds(window);
    Require(login.state == NSControlStateValueOff && !hint.hidden && [hint.stringValue isEqualToString:longError],
            @"Failed changes must restore the actual login state and retain the full error");
    NSRect textBounds = [hint.attributedStringValue boundingRectWithSize:NSMakeSize(hint.bounds.size.width, CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading];
    Require(root.bounds.size.height > baseHeight && hint.bounds.size.height + 2 >= textBounds.size.height,
            @"Long login errors must wrap and grow the window rather than clip");
    Require([privacy.stringValue isEqualToString:privacyText], @"Login feedback must preserve the privacy explanation");
    Capture(window, @"long-error");
    [settings setLoginStatus:SMAppServiceStatusNotRegistered message:nil error:NO];
    Settle(window);
    Require(hint.hidden && root.bounds.size.height <= baseHeight + 1,
            @"Clearing feedback must restore the compact settings height");
    for (NSUInteger iteration = 0; iteration < 20; ++iteration) {
        [settings close];
        [settings showWindow:nil];
        Require(settings.window == window && window.contentView == root,
                @"Closing and reopening must reuse the settings window and view tree");
        CheckBounds(window);
    }
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    Settle(window);
    [window makeFirstResponder:window];
    [window cancelOperation:nil];
    Settle(window);
    Require(!window.visible, @"The Escape responder command must close the settings window");
    [settings showWindow:nil];
    NSEvent *closeKey = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:NSEventModifierFlagCommand timestamp:NSProcessInfo.processInfo.systemUptime
        windowNumber:window.windowNumber context:nil characters:@"w" charactersIgnoringModifiers:@"w"
        isARepeat:NO keyCode:13];
    Require([window performKeyEquivalent:closeKey] && !window.visible,
            @"Command-W must close the settings window");
    std::cout << "settings_smoke_complete=true\nreused_window_cycles=20\ncaptures=settings-smoke\n";
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
