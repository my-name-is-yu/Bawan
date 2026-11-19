#import "ShortcutPreferences.h"

#include <cstdlib>
#include <iostream>

static void require(bool condition, const char *message, NSString *context = nil) {
    if (!condition) {
        std::cerr << "FAIL: " << message;
        if (context) std::cerr << " (" << context.UTF8String << ')';
        std::cerr << '\n';
        std::exit(1);
    }
}

int main() {
    @autoreleasepool {
        NSString *suite = [@"local.bawan.ShortcutPreferencesTests." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        [defaults removePersistentDomainForName:suite];
        ShortcutPreferences *preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        auto initial = bawan::defaultShortcuts();
        require([preferences bindingForAction:bawan::ShortcutAction::TranslateSelection] == initial[0], "selection default");
        require([preferences bindingForAction:bawan::ShortcutAction::OpenPanel] == initial[1], "panel default");
        NSDictionary *defaultStored = @{@"version": @1, @"bindings": @{
            @"translateSelection": @{@"enabled": @YES, @"keyCode": @8, @"modifiers": @1, @"pressCount": @2},
            @"openPanel": @{@"enabled": @YES, @"keyCode": @17, @"modifiers": @2, @"pressCount": @2}}};
        require([[defaults persistentDomainForName:suite] isEqual:@{@"globalShortcuts": defaultStored}],
                "first launch saves the complete default settings");
        require(![preferences bindingForAction:static_cast<bawan::ShortcutAction>(initial.size())].enabled,
                "an unknown action reads as a disabled binding instead of throwing");

        __block unsigned notifications = 0;
        id observer = [NSNotificationCenter.defaultCenter addObserverForName:BawanShortcutsDidChangeNotification
            object:preferences queue:nil usingBlock:^(NSNotification *) { ++notifications; }];
        bawan::ShortcutBinding custom{true, 5, bawan::Option, 1};
        NSString *error = nil;
        require([preferences setBinding:custom forAction:bawan::ShortcutAction::OpenPanel error:&error], "custom key accepted");
        require(error == nil && notifications == 1, "valid change notifies once");
        require([ShortcutKeyLabel(custom) hasPrefix:@"⌥"], "key label includes modifiers");
        require([ShortcutBindingLabel(custom) containsString:@"×1"], "binding label includes press count");
        ShortcutPreferences *reloaded = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        require([reloaded bindingForAction:bawan::ShortcutAction::OpenPanel] == custom, "custom key survives reload");
        custom.enabled = false;
        require([preferences setBinding:custom forAction:bawan::ShortcutAction::OpenPanel error:&error], "row can be disabled");
        reloaded = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        require([reloaded bindingForAction:bawan::ShortcutAction::OpenPanel] == custom, "disabled row retains key and press count");
        require([preferences restoreAction:bawan::ShortcutAction::OpenPanel error:&error], "row restores default");
        require([preferences bindingForAction:bawan::ShortcutAction::OpenPanel] == initial[1], "restore includes enabled state");

        unsigned beforeRejection = notifications;
        bawan::ShortcutBinding duplicate = initial[0];
        duplicate.pressCount = 1;
        require(![preferences setBinding:duplicate forAction:bawan::ShortcutAction::OpenPanel error:&error], "single/double duplicate rejected");
        require([error containsString:ShortcutActionTitle(bawan::ShortcutAction::TranslateSelection)], "duplicate identifies other action");
        require([preferences bindingForAction:bawan::ShortcutAction::OpenPanel] == initial[1], "rejected change preserves value");
        require(notifications == beforeRejection, "rejected change does not notify");
        bawan::ShortcutBinding reserved{true, 8, static_cast<std::uint8_t>(bawan::Command | bawan::Shift), 1};
        require(![preferences setBinding:reserved forAction:bawan::ShortcutAction::OpenPanel error:&error], "fixed copy shortcut rejected");
        require([preferences bindingForAction:bawan::ShortcutAction::OpenPanel] == initial[1], "reserved rejection preserves old binding");

        duplicate.enabled = false;
        require([preferences setBinding:duplicate forAction:bawan::ShortcutAction::OpenPanel error:&error], "disabled duplicate may be retained");
        duplicate.enabled = true;
        require(![preferences setBinding:duplicate forAction:bawan::ShortcutAction::OpenPanel error:&error], "enabling duplicate rejected");
        require(![preferences bindingForAction:bawan::ShortcutAction::OpenPanel].enabled, "rejected enable remains off");
        require([preferences restoreAction:bawan::ShortcutAction::OpenPanel error:&error], "restore after rejected enable");
        [NSNotificationCenter.defaultCenter removeObserver:observer];

        [defaults removePersistentDomainForName:suite];
        [defaults setBool:NO forKey:@"shortcutEnabled"];
        preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        require([preferences bindingForAction:bawan::ShortcutAction::TranslateSelection] == initial[0], "obsolete setting must not override selection default");
        require([preferences bindingForAction:bawan::ShortcutAction::OpenPanel] == initial[1], "obsolete setting must not override panel default");

        NSDictionary *selectionRow = @{@"enabled": @YES, @"keyCode": @2, @"modifiers": @4, @"pressCount": @1};
        NSDictionary *panelRow = @{@"enabled": @NO, @"keyCode": @5, @"modifiers": @2, @"pressCount": @2};
        NSDictionary *validStored = @{@"version": @1, @"bindings": @{
            @"translateSelection": selectionRow, @"openPanel": panelRow}};
        [defaults setObject:validStored forKey:@"globalShortcuts"];
        [defaults setObject:@{@"keep": @[@1, @"unrelated"]} forKey:@"otherPreferences"];
        NSDictionary *validDomain = [defaults persistentDomainForName:suite];
        preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        bawan::ShortcutBindings expectedStored{{{true, 2, bawan::Control, 1}, {false, 5, bawan::Option, 2}}};
        require([preferences bindings] == expectedStored, "valid v1 loads both custom bindings including disabled state");
        require([[defaults persistentDomainForName:suite] isEqual:validDomain], "valid v1 retains saved settings");

        NSDictionary *disabledDuplicate = @{@"enabled": @NO, @"keyCode": @2, @"modifiers": @4, @"pressCount": @2};
        [defaults setObject:@{@"version": @1, @"bindings": @{
            @"translateSelection": selectionRow, @"openPanel": disabledDuplicate}}
            forKey:@"globalShortcuts"];
        preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        bawan::ShortcutBindings expectedDisabledDuplicate{{{true, 2, bawan::Control, 1}, {false, 2, bawan::Control, 2}}};
        require([preferences bindings] == expectedDisabledDuplicate, "a disabled duplicate remains a valid stored binding");

        NSMutableDictionary<NSString *, id> *rejectedPayloads = [@{
            @"unknown version": @{@"version": @2, @"bindings": validStored[@"bindings"], @"future": @[@"preserve", @3]},
            @"string payload": @"keep this value",
            @"array payload": @[validStored],
            @"number payload": @7,
            @"missing version": @{@"bindings": validStored[@"bindings"]},
            @"string version": @{@"version": @"1", @"bindings": validStored[@"bindings"]},
            @"Boolean version": @{@"version": @YES, @"bindings": validStored[@"bindings"]},
            @"fractional version": @{@"version": @1.5, @"bindings": validStored[@"bindings"]},
            @"missing bindings": @{@"version": @1},
            @"non-dictionary bindings": @{@"version": @1, @"bindings": @[selectionRow, panelRow]},
            @"missing first row": @{@"version": @1, @"bindings": @{@"openPanel": panelRow}},
            @"missing second row": @{@"version": @1, @"bindings": @{@"translateSelection": selectionRow}},
            @"invalid first row": @{@"version": @1, @"bindings": @{@"translateSelection": @"bad", @"openPanel": panelRow}},
            @"invalid second row": @{@"version": @1, @"bindings": @{@"translateSelection": selectionRow, @"openPanel": @[]}},
            @"enabled duplicate": @{@"version": @1, @"bindings": @{@"translateSelection": selectionRow, @"openPanel": selectionRow}}
        } mutableCopy];
        NSDictionary<NSString *, NSDictionary *> *invalidFields = @{
            @"string enabled": @{@"enabled": @"YES"},
            @"invalid enabled": @{@"enabled": @2},
            @"string key": @{@"keyCode": @"D"},
            @"Boolean key": @{@"keyCode": @YES},
            @"unsupported key": @{@"keyCode": @52},
            @"negative key": @{@"keyCode": @-1},
            @"string modifiers": @{@"modifiers": @"4"},
            @"Boolean modifiers": @{@"modifiers": @YES},
            @"invalid modifiers": @{@"modifiers": @16},
            @"string count": @{@"pressCount": @"1"},
            @"fractional count": @{@"pressCount": @1.5},
            @"Boolean count": @{@"pressCount": @YES},
            @"zero count": @{@"pressCount": @0}
        };
        for (NSString *name in invalidFields) {
            NSMutableDictionary *row = [selectionRow mutableCopy];
            [row addEntriesFromDictionary:invalidFields[name]];
            rejectedPayloads[name] = @{@"version": @1, @"bindings": @{
                @"translateSelection": row, @"openPanel": panelRow}};
        }
        bawan::ShortcutBinding edited{true, 5, bawan::Option, 1};
        bawan::ShortcutBindings expectedEdited{{initial[0], edited}};
        NSDictionary *editedStored = @{@"version": @1, @"bindings": @{
            @"translateSelection": defaultStored[@"bindings"][@"translateSelection"],
            @"openPanel": @{@"enabled": @YES, @"keyCode": @5, @"modifiers": @2, @"pressCount": @1}}};
        for (NSString *name in rejectedPayloads) {
            [defaults setObject:rejectedPayloads[name] forKey:@"globalShortcuts"];
            NSDictionary *beforeLoad = [defaults persistentDomainForName:suite];
            preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
            require([preferences bindings] == initial, "rejected saved settings use all defaults without partial loading", name);
            require([[defaults persistentDomainForName:suite] isEqual:beforeLoad], "rejected saved settings preserve the entire defaults domain", name);

            __block unsigned editedNotifications = 0;
            observer = [NSNotificationCenter.defaultCenter addObserverForName:BawanShortcutsDidChangeNotification
                object:preferences queue:nil usingBlock:^(NSNotification *) { ++editedNotifications; }];
            require([preferences setBinding:edited forAction:bawan::ShortcutAction::OpenPanel error:&error],
                    "explicit edit after rejected startup data is accepted", name);
            require(error == nil && editedNotifications == 1, "explicit edit after rejected startup data notifies once", name);
            NSMutableDictionary *expectedDomain = [beforeLoad mutableCopy];
            expectedDomain[@"globalShortcuts"] = editedStored;
            require([[defaults persistentDomainForName:suite] isEqual:expectedDomain], "explicit edit replaces rejected data and preserves other settings", name);
            reloaded = [[ShortcutPreferences alloc] initWithDefaults:defaults];
            require([reloaded bindings] == expectedEdited, "explicit edit after rejected startup data survives reload", name);
            [NSNotificationCenter.defaultCenter removeObserver:observer];
        }
        require(ShortcutModifiersFromFlags(NSEventModifierFlagCommand | NSEventModifierFlagCapsLock) == bawan::Command,
                "Caps Lock does not change chord");
        require((ShortcutModifiersFromFlags(NSEventModifierFlagFunction) & bawan::Function) != 0,
                "Fn survives normalization for validation");
        require(ShortcutModifiersFromFlags(NSEventModifierFlagCommand | NSEventModifierFlagFunction, 123) == bawan::Command,
                "arrow-key automatic Fn flag is removed");
        require(ShortcutModifiersFromFlags(NSEventModifierFlagOption | NSEventModifierFlagFunction, 122) == bawan::Option,
                "F-key automatic Fn flag is removed");
        require(ShortcutModifiersFromFlags(NSEventModifierFlagCommand | NSEventModifierFlagFunction, 17) == (bawan::Command | bawan::Function),
                "explicit Fn on typing key remains visible to validation");
        [defaults removePersistentDomainForName:suite];
    }
    std::cout << "Shortcut preferences tests passed\n";
}
