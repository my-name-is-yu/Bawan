#import "SelectionReader.h"
#import "ShortcutPreferences.h"
#import "SystemKeyboardLayout.h"

#include "KeyboardLayoutFixtures.h"

#include <cstdlib>
#include <iostream>
#include <vector>

static void require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

struct BawanCapturedCopyKeyEvent {
    CGEventType type;
    CGEventFlags flags;
    int64_t key;
    int64_t tag;
};

static void requireCopyPair(const bawan::KeyboardLayout& layout, std::uint16_t expectedKey) {
    std::vector<BawanCapturedCopyKeyEvent> events;
    auto *captured = &events;
    require(PostCopyEvents(layout, ^(CGEventRef event) {
        captured->push_back({CGEventGetType(event), CGEventGetFlags(event),
            CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode),
            CGEventGetIntegerValueField(event, kCGEventSourceUserData)});
    }), "a resolved Copy produces a physical keyboard event pair");
    require(events.size() == 2, "Copy emits exactly a down/up pair");
    require(events[0].type == kCGEventKeyDown && events[1].type == kCGEventKeyUp,
            "Copy presses and releases the resolved key in order");
    for (const auto& event : events) {
        require(event.key == expectedKey, "Copy uses the Command-layer physical key");
        require(event.flags == kCGEventFlagMaskCommand, "Copy carries only Command on both events");
        require(event.tag == bawan::selectionCopyEventTag, "the monitor can identify both synthesized Copy events");
    }
}

static void testCopyEvents() {
    requireCopyPair(bawan::test::qwertyLayout(), 8);
    requireCopyPair(bawan::test::dvorakLayout(), 34);
    requireCopyPair(bawan::test::dvorakQwertyCommandLayout(), 8);

    auto ambiguous = bawan::test::qwertyLayout();
    ambiguous.command[34] = u'c';
    for (const auto& layout : {bawan::KeyboardLayout{}, ambiguous}) {
        __block unsigned delivered = 0;
        require(!PostCopyEvents(layout, ^(CGEventRef) { ++delivered; }),
                "missing or ambiguous Copy resolution reports failure");
        require(delivered == 0, "unresolved Copy never emits a partial or guessed event pair");
    }
}

static void testCommandLabels() {
    const auto dvorak = bawan::test::dvorakLayout();
    const auto hybrid = bawan::test::dvorakQwertyCommandLayout();
    bawan::ShortcutBinding binding{true, 8, bawan::Command, 1};
    require([ShortcutKeyLabel(binding, dvorak) isEqualToString:@"⌘J"],
            "standard Dvorak shows the actual Command character for the saved physical key");
    require([ShortcutKeyLabel(binding, hybrid) isEqualToString:@"⌘C"],
            "Dvorak-QWERTY Command labels use its Command layer");
    binding.modifiers = bawan::Option;
    require([ShortcutKeyLabel(binding, hybrid) isEqualToString:@"⌥J"],
            "a shortcut without Command uses the plain Dvorak layer");
    binding.modifiers = bawan::Command | bawan::Shift;
    require([ShortcutKeyLabel(binding, hybrid) isEqualToString:@"⇧⌘C"],
            "Command-Shift labels use the matching shifted Command layer");
    binding.keyCode = 34;
    binding.modifiers = bawan::Command;
    require([ShortcutKeyLabel(binding, dvorak) isEqualToString:@"⌘C"],
            "Dvorak Copy is labeled at its resolved physical position");
    require([ShortcutKeyLabel(binding, bawan::KeyboardLayout{}) isEqualToString:@"⌘Key 34"],
            "missing layout data shows a physical-key fallback without claiming a character");
    binding.keyCode = bawan::unresolvedShortcutKey;
    require([ShortcutKeyLabel(binding, dvorak) isEqualToString:@"Unavailable"],
            "an unresolved default is visibly unavailable");
}

static void testSavedPhysicalKeyAfterLayoutChange() {
    NSString *suite = [@"local.bawan.KeyboardLayoutNativeTests." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removePersistentDomainForName:suite];
    __block bawan::KeyboardLayout layout = bawan::test::qwertyLayout();
    bawan::KeyboardLayout (^provider)(void) = ^{ return layout; };
    ShortcutPreferences *preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults layoutProvider:provider];
    const bawan::ShortcutBinding saved{true, 7, bawan::Command, 1};
    NSString *error = nil;
    require([preferences setBinding:saved forAction:bawan::ShortcutAction::OpenPanel error:&error],
            "a user can save Command-X on QWERTY");

    layout = bawan::test::dvorakLayout();
    require([preferences bindingForAction:bawan::ShortcutAction::OpenPanel] == saved,
            "a layout change preserves the saved physical key");
    require([ShortcutKeyLabel(saved, preferences.keyboardLayout) isEqualToString:@"⌘Q"],
            "the saved key label follows the new source's Command layer");
    require(![preferences setBinding:saved forAction:bawan::ShortcutAction::OpenPanel error:&error] && error.length,
            "the same physical key is now rejected as the Dvorak Quit reservation");
    require([preferences bindingForAction:bawan::ShortcutAction::OpenPanel] == saved,
            "reservation rejection does not silently remap an existing binding");
    require([preferences setBinding:bawan::ShortcutBinding{true, 40, bawan::Option, 1}
        forAction:bawan::ShortcutAction::TranslateSelection error:&error] && !error,
        "a newly reserved stored binding does not prevent editing the other action");
    ShortcutPreferences *reloaded = [[ShortcutPreferences alloc] initWithDefaults:defaults layoutProvider:provider];
    require([reloaded bindingForAction:bawan::ShortcutAction::OpenPanel] == saved,
            "the physical binding survives reload under a different layout");

    layout = bawan::test::dvorakQwertyCommandLayout();
    require([ShortcutKeyLabel(saved, reloaded.keyboardLayout) isEqualToString:@"⌘X"],
            "returning to a QWERTY Command layer updates the displayed meaning");
    require([reloaded setBinding:saved forAction:bawan::ShortcutAction::OpenPanel error:&error] && !error,
            "the physical key becomes available when its Command meaning changes back");
    [defaults removePersistentDomainForName:suite];
}

static TISInputSourceRef copyInstalledLayout(NSString *identifier) {
    NSDictionary *filter = @{(__bridge NSString *)kTISPropertyInputSourceID: identifier};
    CFArrayRef sources = TISCreateInputSourceList((__bridge CFDictionaryRef)filter, true);
    if (!sources) return nullptr;
    TISInputSourceRef found = nullptr;
    for (CFIndex index = 0; index < CFArrayGetCount(sources); ++index) {
        auto source = (TISInputSourceRef)CFArrayGetValueAtIndex(sources, index);
        auto actualID = static_cast<CFStringRef>(TISGetInputSourceProperty(source, kTISPropertyInputSourceID));
        if (actualID && CFEqual(actualID, (__bridge CFStringRef)identifier)) {
            found = source;
            CFRetain(found);
            break;
        }
    }
    CFRelease(sources);
    return found;
}

static void testInstalledLayout(NSString *identifier, char16_t plainAtEight,
                                char16_t commandAtEight, std::uint16_t copyKey) {
    TISInputSourceRef source = copyInstalledLayout(identifier);
    if (!source) {
        std::cout << "SKIP: installed layout unavailable: " << identifier.UTF8String << '\n';
        return;
    }
    const auto layout = KeyboardLayoutForInputSource(source, LMGetKbdType());
    CFRelease(source);
    std::cout << "Checking installed layout: " << identifier.UTF8String << '\n';
    require(layout.character(8, bawan::KeyboardLayer::Plain) == plainAtEight,
            "Apple's unselected layout translates the physical C position as expected");
    require(layout.character(8, bawan::KeyboardLayer::Command) == commandAtEight,
            "Apple's unselected layout preserves its actual Command-layer behavior");
    require(layout.copyKey() == copyKey,
            "Apple layout data resolves the unique physical Copy key");
    requireCopyPair(layout, copyKey);
}

int main() {
    @autoreleasepool {
        require(NSThread.isMainThread, "native keyboard layout APIs run on the main thread");
        testCopyEvents();
        testCommandLabels();
        testSavedPhysicalKeyAfterLayoutChange();
        testInstalledLayout(@"com.apple.keylayout.ABC", u'c', u'c', 8);
        testInstalledLayout(@"com.apple.keylayout.Dvorak", u'j', u'j', 34);
        testInstalledLayout(@"com.apple.keylayout.DVORAK-QWERTYCMD", u'j', u'c', 8);
        require(!KeyboardLayoutForInputSource(nullptr, LMGetKbdType()).copyKey(),
                "a missing input source cannot resolve a guessed Copy key");
        std::cout << "Native keyboard layout tests passed without posting events or selecting input sources\n";
    }
}
