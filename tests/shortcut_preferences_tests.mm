#import "ShortcutPreferences.h"

#include <cstdlib>
#include <iostream>

static void require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

static bool equal(lore::ShortcutBinding lhs, lore::ShortcutBinding rhs) {
    return lhs.enabled == rhs.enabled && lhs.keyCode == rhs.keyCode &&
        lhs.modifiers == rhs.modifiers && lhs.pressCount == rhs.pressCount;
}

int main() {
    @autoreleasepool {
        NSString *suite = [@"local.lore.ShortcutPreferencesTests." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        [defaults removePersistentDomainForName:suite];
        ShortcutPreferences *preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        auto initial = lore::defaultShortcuts();
        require(equal([preferences bindingForAction:lore::ShortcutAction::TranslateSelection], initial[0]), "selection default");
        require(equal([preferences bindingForAction:lore::ShortcutAction::OpenPanel], initial[1]), "panel default");

        __block unsigned notifications = 0;
        id observer = [NSNotificationCenter.defaultCenter addObserverForName:LoreShortcutsDidChangeNotification
            object:preferences queue:nil usingBlock:^(NSNotification *) { ++notifications; }];
        lore::ShortcutBinding custom{true, 5, lore::Option, 1};
        NSString *error = nil;
        require([preferences setBinding:custom forAction:lore::ShortcutAction::OpenPanel error:&error], "custom key accepted");
        require(error == nil && notifications == 1, "valid change notifies once");
        require([ShortcutKeyLabel(custom) hasPrefix:@"⌥"], "key label includes modifiers");
        require([ShortcutBindingLabel(custom) containsString:@"×1"], "binding label includes press count");
        ShortcutPreferences *reloaded = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        require(equal([reloaded bindingForAction:lore::ShortcutAction::OpenPanel], custom), "custom key survives reload");
        custom.enabled = false;
        require([preferences setBinding:custom forAction:lore::ShortcutAction::OpenPanel error:&error], "row can be disabled");
        reloaded = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        require(equal([reloaded bindingForAction:lore::ShortcutAction::OpenPanel], custom), "disabled row retains key and press count");
        require([preferences restoreAction:lore::ShortcutAction::OpenPanel error:&error], "row restores default");
        require(equal([preferences bindingForAction:lore::ShortcutAction::OpenPanel], initial[1]), "restore includes enabled state");

        unsigned beforeRejection = notifications;
        lore::ShortcutBinding duplicate = initial[0];
        duplicate.pressCount = 1;
        require(![preferences setBinding:duplicate forAction:lore::ShortcutAction::OpenPanel error:&error], "single/double duplicate rejected");
        require([error containsString:ShortcutActionTitle(lore::ShortcutAction::TranslateSelection)], "duplicate identifies other action");
        require(equal([preferences bindingForAction:lore::ShortcutAction::OpenPanel], initial[1]), "rejected change preserves value");
        require(notifications == beforeRejection, "rejected change does not notify");
        lore::ShortcutBinding reserved{true, 8, static_cast<std::uint8_t>(lore::Command | lore::Shift), 1};
        require(![preferences setBinding:reserved forAction:lore::ShortcutAction::OpenPanel error:&error], "fixed copy shortcut rejected");
        require(equal([preferences bindingForAction:lore::ShortcutAction::OpenPanel], initial[1]), "reserved rejection preserves old binding");

        duplicate.enabled = false;
        require([preferences setBinding:duplicate forAction:lore::ShortcutAction::OpenPanel error:&error], "disabled duplicate may be retained");
        duplicate.enabled = true;
        require(![preferences setBinding:duplicate forAction:lore::ShortcutAction::OpenPanel error:&error], "enabling duplicate rejected");
        require(![preferences bindingForAction:lore::ShortcutAction::OpenPanel].enabled, "rejected enable remains off");
        require([preferences restoreAction:lore::ShortcutAction::OpenPanel error:&error], "restore after rejected enable");
        [NSNotificationCenter.defaultCenter removeObserver:observer];

        [defaults removePersistentDomainForName:suite];
        [defaults setBool:NO forKey:@"shortcutEnabled"];
        preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        require(![preferences bindingForAction:lore::ShortcutAction::TranslateSelection].enabled, "legacy off migrated");
        require([preferences bindingForAction:lore::ShortcutAction::OpenPanel].enabled, "new panel action defaults on");
        lore::ShortcutBinding selection = [preferences bindingForAction:lore::ShortcutAction::TranslateSelection];
        selection.enabled = true;
        require([preferences setBinding:selection forAction:lore::ShortcutAction::TranslateSelection error:&error], "migration does not prevent new changes");
        reloaded = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        require([reloaded bindingForAction:lore::ShortcutAction::TranslateSelection].enabled, "modern value overrides legacy value");

        [defaults setObject:@{@"version": @1, @"bindings": @{
            @"translateSelection": @{@"enabled": @YES, @"keyCode": @"C", @"modifiers": @1, @"pressCount": @2},
            @"openPanel": @{@"enabled": @YES, @"keyCode": @17, @"modifiers": @2, @"pressCount": @1.5}}}
            forKey:@"globalShortcuts"];
        preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        require(![preferences bindingForAction:lore::ShortcutAction::TranslateSelection].enabled, "corrupt row preserves legacy off fallback");
        require(equal([preferences bindingForAction:lore::ShortcutAction::OpenPanel], initial[1]), "fractional count falls back to default");

        NSDictionary *sameRow = @{@"enabled": @YES, @"keyCode": @8, @"modifiers": @1, @"pressCount": @2};
        [defaults setObject:@{@"version": @1, @"bindings": @{@"translateSelection": sameRow, @"openPanel": sameRow}}
            forKey:@"globalShortcuts"];
        preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        require([preferences bindingForAction:lore::ShortcutAction::TranslateSelection].enabled, "valid stored selection survives conflict");
        require(![preferences bindingForAction:lore::ShortcutAction::OpenPanel].enabled, "corrupt stored conflict disables duplicate reservation");
        require(ShortcutModifiersFromFlags(NSEventModifierFlagCommand | NSEventModifierFlagCapsLock) == lore::Command,
                "Caps Lock does not change chord");
        require((ShortcutModifiersFromFlags(NSEventModifierFlagFunction) & lore::Function) != 0,
                "Fn survives normalization for validation");
        require(ShortcutModifiersFromFlags(NSEventModifierFlagCommand | NSEventModifierFlagFunction, 123) == lore::Command,
                "arrow-key automatic Fn flag is removed");
        require(ShortcutModifiersFromFlags(NSEventModifierFlagOption | NSEventModifierFlagFunction, 122) == lore::Option,
                "F-key automatic Fn flag is removed");
        require(ShortcutModifiersFromFlags(NSEventModifierFlagCommand | NSEventModifierFlagFunction, 17) == (lore::Command | lore::Function),
                "explicit Fn on typing key remains visible to validation");
        [defaults removePersistentDomainForName:suite];
    }
    std::cout << "Shortcut preferences tests passed\n";
}
