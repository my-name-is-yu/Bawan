#include "ShortcutBinding.h"

#include <cstdlib>
#include <iostream>

using namespace lore;
using Kind = ShortcutEvent::Kind;

static void require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

static ShortcutEvent event(Kind kind, std::uint64_t milliseconds, std::uint16_t key = 17,
                           std::uint8_t modifiers = Option, std::int64_t app = 10,
                           bool repeat = false) {
    return {kind, key, modifiers, repeat, app, milliseconds * 1'000'000};
}

static void testBindings() {
    auto bindings = defaultShortcuts();
    require(validateShortcuts(bindings) == ShortcutError::None, "defaults are valid");
    require(isPassiveCopy(bindings[0]) && !isPassiveCopy(bindings[1]), "only Cmd-C twice is passive");
    bindings[0].enabled = false;
    require(isPassiveCopy(bindings[0]), "passive classification is independent of enable state");
    bindings[0].pressCount = 1;
    require(!isPassiveCopy(bindings[0]), "single Cmd-C is active");

    bindings = defaultShortcuts();
    bindings[1] = bindings[0];
    bindings[1].pressCount = 1;
    require(validateShortcuts(bindings) == ShortcutError::Duplicate, "single and double prefixes conflict");
    bindings[1].enabled = false;
    require(validateShortcuts(bindings) == ShortcutError::None, "disabled duplicate can be retained");
    bindings[1].enabled = true;
    require(validateShortcuts(bindings) == ShortcutError::Duplicate, "re-enabling duplicate is rejected");

    for (std::uint8_t modifiers : {std::uint8_t(0), std::uint8_t(Shift), std::uint8_t(Command | Function)}) {
        auto binding = defaultShortcuts()[1];
        binding.modifiers = modifiers;
        require(validateShortcut(binding) == ShortcutError::MissingModifier, "plain, shift-only and Fn shortcuts are rejected");
    }
    for (std::uint16_t key : {54, 55, 56, 57, 58, 59, 63, 72, 73, 74, 127, 255}) {
        auto binding = defaultShortcuts()[1];
        binding.keyCode = key;
        require(validateShortcut(binding) == ShortcutError::InvalidKey, "modifier and media keys are rejected");
    }
    for (std::uint16_t key : {0, 10, 17, 18, 43, 48, 49, 51, 53, 64, 76, 90, 93, 95, 122, 123, 126}) {
        auto binding = defaultShortcuts()[1];
        binding.keyCode = key;
        require(validateShortcut(binding) == ShortcutError::None, "typing, keypad, function and navigation keys are supported");
    }
    for (std::uint16_t key : {36, 76, 12, 43}) {
        ShortcutBinding binding{true, key, Command, 2};
        require(validateShortcut(binding) == ShortcutError::Reserved, "Lore's fixed commands cannot be shadowed by a prefix");
    }
    require(validateShortcut({true, 8, std::uint8_t(Command | Shift), 1}) == ShortcutError::Reserved,
            "copy-result command is reserved");
    require(validateShortcut({true, 17, Option, 3}) == ShortcutError::InvalidPressCount,
            "only one or two presses are supported");
    for (std::uint16_t key : {64, 79, 80, 90, 96, 97, 98, 99, 100, 101, 103, 105, 106,
                              107, 109, 111, 113, 114, 115, 116, 117, 118, 119, 120,
                              121, 122, 123, 124, 125, 126}) {
        require(normalizeShortcutModifiers(std::uint8_t(Command | Function), key) == Command,
                "automatic Fn flag does not prevent function/navigation shortcuts");
    }
    require(normalizeShortcutModifiers(std::uint8_t(Command | Function), 17) == (Command | Function),
            "explicit Fn on a typing key remains unsupported");
    require(normalizeShortcutModifiers(std::uint8_t(Control | Option | Shift), 123) == (Control | Option | Shift),
            "normalization preserves chosen modifiers");
}

static void testDoublePress() {
    ShortcutGesture gesture;
    const auto binding = defaultShortcuts()[1];
    gesture.configure(binding, true);
    auto result = gesture.handle(event(Kind::KeyDown, 100));
    require(result.firstPress && result.consumed && !result.triggered, "first Option-T is reserved but does not trigger");
    result = gesture.handle(event(Kind::KeyUp, 150));
    require(result.released && result.consumed, "release is swallowed with its down event");
    result = gesture.handle(event(Kind::KeyDown, 500));
    require(result.triggered && !result.firstPress && result.consumed, "400ms boundary triggers");
    require(!gesture.handle(event(Kind::KeyDown, 501, 17, Option, 10, true)).triggered,
            "repeat does not retrigger");
    gesture.handle(event(Kind::KeyUp, 520));
    require(gesture.handle(event(Kind::KeyDown, 550)).firstPress, "third tap starts a new pair");

    gesture.configure(binding, true);
    gesture.handle(event(Kind::KeyDown, 100));
    require(!gesture.handle(event(Kind::KeyDown, 200)).triggered, "a release is required");
    require(gesture.handle(event(Kind::KeyDown, 250, 17, Option, 10, true)).consumed,
            "long-held key stays swallowed");
    gesture.handle(event(Kind::KeyUp, 300));
    require(gesture.handle(event(Kind::KeyDown, 350)).firstPress, "long hold cancels the old pair");

    gesture.configure(binding, true);
    gesture.handle(event(Kind::KeyDown, 100));
    gesture.handle(event(Kind::KeyUp, 150));
    require(gesture.handle(event(Kind::KeyDown, 501)).firstPress, "401ms starts a new pair");
    gesture.handle(event(Kind::KeyUp, 510));
    require(gesture.handle(event(Kind::KeyDown, 550)).triggered, "new pair remains usable");

    for (auto interruption : {
            event(Kind::KeyDown, 175, 0),
            event(Kind::FlagsChanged, 175, 58, 0),
            event(Kind::FlagsChanged, 175, 56, std::uint8_t(Option | Shift)),
            event(Kind::KeyDown, 175, 17, std::uint8_t(Option | Command))}) {
        gesture.configure(binding, true);
        gesture.handle(event(Kind::KeyDown, 100));
        gesture.handle(event(Kind::KeyUp, 150));
        gesture.handle(interruption);
        gesture.handle(event(Kind::KeyUp, 200, interruption.keyCode, interruption.modifiers));
        require(gesture.handle(event(Kind::KeyDown, 250)).firstPress,
                "other keys, Option release and added modifiers cancel a pair");
    }

    gesture.configure(binding, true);
    gesture.handle(event(Kind::KeyDown, 100));
    gesture.handle(event(Kind::FlagsChanged, 120, 58, 0));
    require(gesture.handle(event(Kind::KeyDown, 130, 17, 0, 10, true)).consumed,
            "repeats stay swallowed after Option is released");
    require(gesture.handle(event(Kind::KeyUp, 150, 17, 0)).consumed,
            "Option can be released before the swallowed key-up");
    require(gesture.handle(event(Kind::KeyDown, 200)).firstPress,
            "Option release prevents completing a prior pair");

    gesture.configure(binding, true);
    gesture.handle(event(Kind::KeyDown, 100));
    gesture.cancel();
    require(gesture.handle(event(Kind::KeyUp, 150)).consumed, "cancellation retains swallowed key ownership");
    require(gesture.handle(event(Kind::KeyDown, 200)).firstPress, "explicit cancellation disarms");

    gesture.configure(binding, true);
    gesture.handle(event(Kind::KeyDown, 100));
    require(gesture.handle(event(Kind::KeyUp, 150, 17, Option, 20)).consumed,
            "app switches do not leak a swallowed key-up");
    require(gesture.handle(event(Kind::KeyDown, 200, 17, Option, 20)).firstPress,
            "app switch cancels the old pair");
    gesture.handle(event(Kind::KeyUp, 210, 17, Option, 20));
    require(gesture.handle(event(Kind::KeyDown, 250, 17, Option, 20)).triggered,
            "new app can form a fresh pair");

    gesture.configure(binding, true);
    gesture.handle(event(Kind::KeyDown, 100));
    gesture.handle(event(Kind::KeyUp, 150));
    require(gesture.handle(event(Kind::KeyDown, 90)).firstPress, "backwards timestamps cannot complete a pair");
}

static void testSingleAndPassive() {
    ShortcutGesture gesture;
    ShortcutBinding binding{true, 40, std::uint8_t(Control | Option), 1};
    gesture.configure(binding, true);
    auto result = gesture.handle(event(Kind::KeyDown, 100, 40, binding.modifiers));
    require(result.triggered && result.consumed, "arbitrary single chord fires on first down");
    require(!gesture.handle(event(Kind::KeyDown, 200, 40, binding.modifiers, 10, true)).triggered,
            "single chord fires once while held");
    require(gesture.handle(event(Kind::KeyUp, 250, 40, binding.modifiers)).released,
            "single chord reports release for deferred copying");
    require(gesture.handle(event(Kind::KeyDown, 300, 40, binding.modifiers)).triggered,
            "single chord is available after release");
    binding.enabled = false;
    gesture.configure(binding, true);
    result = gesture.handle(event(Kind::KeyDown, 100, 40, binding.modifiers));
    require(!result.triggered && !result.consumed, "disabled shortcut restores normal typing");

    gesture.configure(defaultShortcuts()[0], false);
    result = gesture.handle(event(Kind::KeyDown, 100, 8, Command));
    require(result.firstPress && !result.consumed, "default copy first press stays passive");
    gesture.handle(event(Kind::KeyUp, 150, 8, 0));
    gesture.handle(event(Kind::FlagsChanged, 180, 55, 0));
    result = gesture.handle(event(Kind::KeyDown, 300, 8, Command));
    require(result.triggered && !result.consumed, "Command may be re-pressed between passive copies");
    gesture.handle(event(Kind::KeyUp, 310, 8, Command));
    gesture.handle(event(Kind::KeyDown, 400, 8, Command));
    gesture.handle(event(Kind::KeyUp, 410, 8, Command));
    gesture.handle(event(Kind::KeyDown, 450, 0, Command));
    require(gesture.handle(event(Kind::KeyDown, 480, 8, Command)).firstPress,
            "other keys cancel passive copy pairs too");
}

int main() {
    testBindings();
    testDoublePress();
    testSingleAndPassive();
    std::cout << "Shortcut binding and gesture tests passed\n";
}
