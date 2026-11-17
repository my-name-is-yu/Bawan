#include "KeyboardLayout.h"
#include "ShortcutBinding.h"
#include "KeyboardLayoutFixtures.h"

#include <cstdlib>
#include <iostream>

using namespace bawan;

static void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

static void testCopyResolution() {
    const auto qwerty = test::qwertyLayout();
    const auto dvorak = test::dvorakLayout();
    const auto mixed = test::dvorakQwertyCommandLayout();
    require(qwerty.copyKey() == 8, "QWERTY Copy resolves to physical C");
    require(dvorak.copyKey() == 34, "Dvorak Copy resolves to physical I");
    require(dvorak.character(8, KeyboardLayer::Command) == u'j', "physical C is not Dvorak Copy");
    require(mixed.copyKey() == 8, "Dvorak-QWERTY Command Copy uses the Command layer");
    require(mixed.character(8, KeyboardLayer::Plain) == u'j' &&
            mixed.character(8, KeyboardLayer::Command) == u'c',
            "the same physical key can have different plain and Command labels");
    require(mixed.character(34, KeyboardLayer::Plain) == u'c' &&
            mixed.character(34, KeyboardLayer::Command) == u'i',
            "plain Copy position cannot substitute for Command Copy position");

    KeyboardLayout unknown;
    require(!unknown.copyKey(), "unavailable translations have no Copy key");
    unknown.command[0] = u'C';
    require(unknown.copyKey() == 0, "a unique Copy at keyCode zero is usable");
    unknown.command[8] = u'c';
    require(!unknown.copyKey(), "multiple Copy positions fail reverse resolution safely");
    require(unknown.matches(0, KeyboardLayer::Command, u'c') &&
            unknown.matches(8, KeyboardLayer::Command, u'C'),
            "forward recognition still identifies both equivalent Copy keys");
    require(unknown.character(128, KeyboardLayer::Command) == 0 &&
            unknown.character(UINT16_MAX, KeyboardLayer::CommandShift) == 0,
            "out-of-range keys have no translated label");
    KeyboardLayout modifier;
    modifier.command[55] = u'c';
    require(!modifier.copyKey(), "a modifier key cannot become a synthesized Copy candidate");
}

static void testTranslationBoundary() {
    const auto layout = readKeyboardLayout([](std::uint16_t key, KeyboardLayer layer) -> KeyTranslation {
        if (layer == KeyboardLayer::Plain) return {u"p", false};
        if (layer == KeyboardLayer::CommandShift) return {u"Z", false};
        switch (key) {
            case 0: return {u"C", false};
            case 1: return {u"c", true};
            case 2: return {u"", false};
            case 3: return {u"cc", false};
            case 4: return {u"\n", false};
            case 5: return {std::u16string(1, 0x7f), false};
            case 6: return {std::u16string(1, 0x85), false};
            case 7: return {std::u16string(1, 0xd800), false};
            case 8: return {u"\U0001f600", false};
            case 9: return {u"é", false};
            default: return {};
        }
    });
    require(layout.copyKey() == 0, "uppercase ASCII Copy is accepted and matched case-insensitively");
    require(layout.character(0, KeyboardLayer::Command) == u'C', "accepted label preserves translated case");
    for (std::uint16_t key = 1; key <= 8; ++key) {
        require(layout.character(key, KeyboardLayer::Command) == 0,
                "dead, empty, multicharacter, control and surrogate outputs are unusable");
    }
    require(layout.character(9, KeyboardLayer::Command) == u'é', "a printable BMP label is preserved");
    require(!layout.matches(9, KeyboardLayer::Command, u'c'), "non-ASCII label does not become Copy");
    require(layout.character(0, KeyboardLayer::Plain) == u'p' &&
            layout.character(0, KeyboardLayer::CommandShift) == u'Z',
            "each keyboard layer is translated independently");
}

static void testDefaultAndPassiveCopy() {
    for (const auto& layout : {test::qwertyLayout(), test::dvorakLayout(), test::dvorakQwertyCommandLayout()}) {
        const auto defaults = defaultShortcuts(layout);
        require(defaults[0].enabled && defaults[0].keyCode == layout.copyKey(), "selection default uses resolved Copy");
        require(isPassiveCopy(defaults[0], layout), "resolved default is passive Copy");
        require(!isPassiveCopy(defaults[1], layout), "panel default is active");
        auto copy = defaults[0];
        copy.enabled = false;
        require(isPassiveCopy(copy, layout), "passive classification does not depend on enabled state");
        copy.pressCount = 1;
        require(!isPassiveCopy(copy, layout), "one-press Copy is an active custom binding");
        copy.pressCount = 2;
        copy.modifiers |= Shift;
        require(!isPassiveCopy(copy, layout), "extra modifiers do not become passive Copy");
        require(validateShortcuts(defaults, layout) == ShortcutError::None, "resolved defaults remain valid");
    }
    require(!isPassiveCopy({true, 8, Command, 2}, test::dvorakLayout()), "physical US C is active on Dvorak");
    const auto unresolved = defaultShortcuts(KeyboardLayout{});
    require(!unresolved[0].enabled && unresolved[0].keyCode == unresolvedShortcutKey,
            "unresolved Copy disables its default without guessing a physical key");
    require(!isPassiveCopy(unresolved[0], KeyboardLayout{}) &&
            validateShortcuts(unresolved) == ShortcutError::None,
            "an unresolved disabled default is safe to retain");
    require(validateShortcut({false, unresolvedShortcutKey, 0, 2}) == ShortcutError::MissingModifier &&
            validateShortcut({false, unresolvedShortcutKey, Command, 0}) == ShortcutError::InvalidPressCount,
            "the unresolved sentinel does not bypass other saved-field validation");
}

static void testNativeAndReservedCommands() {
    const auto qwerty = test::qwertyLayout();
    const auto dvorak = test::dvorakLayout();
    const auto mixed = test::dvorakQwertyCommandLayout();
    for (const auto key : {0, 6, 7, 8, 9, 13}) {
        require(isNativeWindowShortcut(key, Command, qwerty), "QWERTY editing commands keep native priority");
        require(isNativeWindowShortcut(key, Command, mixed), "Dvorak-QWERTY Command keeps QWERTY native positions");
    }
    for (const auto key : {0, 44, 11, 34, 47, 43}) {
        require(isNativeWindowShortcut(key, Command, dvorak), "Dvorak editing commands follow Command characters");
        require(!isNativeWindowShortcut(key, Option, dvorak) &&
                !isNativeWindowShortcut(key, Command | Option, dvorak),
                "extra modifiers preserve custom shortcut behavior");
    }
    require(!isNativeWindowShortcut(8, Command, dvorak), "Dvorak Command-J is not native Copy");
    require(isNativeWindowShortcut(44, Command | Shift, dvorak) &&
            !isNativeWindowShortcut(6, Command | Shift, dvorak), "Dvorak Redo moves with Z");
    for (const auto key : {7, 13}) {
        require(isReservedShortcut(key, Command, dvorak), "Dvorak Quit and Preferences follow characters");
        require(validateShortcut({true, static_cast<std::uint16_t>(key), Command, 1}, dvorak) == ShortcutError::Reserved,
                "Dvorak app commands cannot be assigned");
    }
    for (const auto key : {12, 43}) {
        require(isReservedShortcut(key, Command, qwerty) && isReservedShortcut(key, Command, mixed),
                "QWERTY Command layers reserve Q and comma");
        require(!isReservedShortcut(key, Command, dvorak), "old physical reservations do not remain on Dvorak");
    }
    for (const auto key : {36, 76}) {
        require(isReservedShortcut(key, Command, dvorak), "both Return keys remain physically reserved");
    }
    require(isReservedShortcut(34, Command | Shift, dvorak) &&
            !isReservedShortcut(8, Command | Shift, dvorak), "Copy Translation follows shifted Command C");

    auto split = qwerty;
    split.commandShift[6] = u'Y';
    split.commandShift[40] = u'Z';
    split.commandShift[8] = u'J';
    split.commandShift[41] = u'C';
    require(isNativeWindowShortcut(40, Command | Shift, split) &&
            !isNativeWindowShortcut(6, Command | Shift, split), "Redo reads Command-Shift separately");
    require(isReservedShortcut(41, Command | Shift, split) &&
            !isReservedShortcut(8, Command | Shift, split), "reservation reads Command-Shift separately");
    require(split.character(41, KeyboardLayer::CommandShift) == u'C', "shifted command label follows its own layer");
    require(isPassiveCopy({true, 8, Command, 2}, split), "shifted layer changes do not move ordinary Copy");

    const ShortcutBinding physicalQ{true, 12, Command, 1};
    require(validateShortcut(physicalQ) == ShortcutError::None &&
            validateShortcut(physicalQ, qwerty) == ShortcutError::Reserved &&
            validateShortcut(physicalQ, dvorak) == ShortcutError::None,
            "stored physical validity is independent of current-layout reservations");
    for (const auto modifiers : {std::uint8_t(Command), std::uint8_t(Command | Shift)}) {
        require(isReservedShortcut(8, modifiers, KeyboardLayout{}) &&
                isNativeWindowShortcut(8, modifiers, KeyboardLayout{}),
                "unknown typing commands pass through instead of shadowing an unresolved native command");
    }
    require(!isReservedShortcut(8, Command | Option, KeyboardLayout{}),
            "unavailable layout data does not block unrelated modifier combinations");
}

int main() {
    testCopyResolution();
    testTranslationBoundary();
    testDefaultAndPassiveCopy();
    testNativeAndReservedCommands();
    std::cout << "Keyboard layout tests passed\n";
}
