#include "ShortcutBinding.h"
#include "ShortcutMonitorState.h"

#include <cstdlib>
#include <iostream>

using namespace bawan;
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
        require(validateShortcut(binding) == ShortcutError::Reserved, "Bawan's fixed commands cannot be shadowed by a prefix");
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
    struct Mode { ShortcutBinding binding; bool consumed; };
    const Mode modes[] = {{defaultShortcuts()[1], true}, {defaultShortcuts()[0], false}};
    for (const auto &mode : modes) {
        ShortcutGesture gesture;
        const auto matching = [&](Kind kind, std::uint64_t time, std::int64_t app = 10, bool repeat = false) {
            return event(kind, time, mode.binding.keyCode, mode.binding.modifiers, app, repeat);
        };
        struct Timing { std::uint64_t second; bool triggers; };
        for (const auto &timing : {Timing{500, true}, Timing{501, false}, Timing{90, false}}) {
            gesture.configure(mode.binding, mode.consumed);
            auto result = gesture.handle(matching(Kind::KeyDown, 100));
            require(result.firstPress && !result.triggered && result.consumed == mode.consumed,
                    "first tap arms without triggering, preserving active/passive delivery");
            result = gesture.handle(matching(Kind::KeyUp, 150));
            require(!result.triggered && result.consumed == mode.consumed,
                    "key release preserves active/passive event delivery without triggering");
            result = gesture.handle(matching(Kind::KeyDown, timing.second));
            require(result.triggered == timing.triggers && result.firstPress == !timing.triggers &&
                    result.consumed == mode.consumed,
                    "400ms is inclusive; 401ms and backwards time begin a new pair");
            if (!timing.triggers) {
                gesture.handle(matching(Kind::KeyUp, timing.second + 10));
                require(gesture.handle(matching(Kind::KeyDown, timing.second + 20)).triggered,
                        "an expired or backwards interval can immediately form a fresh pair");
            }
            result = gesture.handle(matching(Kind::KeyDown, timing.second + 21, 10, true));
            require(!result.triggered && result.consumed == mode.consumed,
                    "a held repeat never retriggers or changes event delivery");
            gesture.handle(matching(Kind::KeyUp, timing.second + 30));
            require(gesture.handle(matching(Kind::KeyDown, timing.second + 50)).firstPress,
                    "after a completed pair or a held repeat, the next tap starts fresh");
        }

        gesture.configure(mode.binding, mode.consumed);
        gesture.handle(matching(Kind::KeyDown, 100));
        auto result = gesture.handle(matching(Kind::KeyDown, 200));
        require(!result.triggered && result.consumed == mode.consumed, "two downs require a key release");
        result = gesture.handle(matching(Kind::KeyDown, 250, 10, true));
        require(!result.triggered && result.consumed == mode.consumed, "a long hold retains event delivery");
        gesture.handle(matching(Kind::KeyUp, 300));
        require(gesture.handle(matching(Kind::KeyDown, 350)).firstPress, "long hold cancels the old pair");

        for (auto interruption : {
                event(Kind::KeyDown, 175, 0, mode.binding.modifiers),
                event(Kind::KeyDown, 175, mode.binding.keyCode, 0),
                event(Kind::KeyDown, 175, mode.binding.keyCode, Shift),
                event(Kind::KeyDown, 175, mode.binding.keyCode, std::uint8_t(mode.binding.modifiers | Shift)),
                event(Kind::KeyDown, 175, mode.binding.keyCode, std::uint8_t(Command | Option))}) {
            gesture.configure(mode.binding, mode.consumed);
            gesture.handle(matching(Kind::KeyDown, 100));
            gesture.handle(matching(Kind::KeyUp, 150));
            require(!gesture.handle(interruption).triggered, "other keys or modifiers cannot complete a pair");
            gesture.handle(event(Kind::KeyUp, 200, interruption.keyCode, interruption.modifiers));
            require(gesture.handle(matching(Kind::KeyDown, 250)).firstPress,
                    "other keys and mismatched chords cancel the old pair");
        }

        for (const bool switchOnRelease : {false, true}) {
            gesture.configure(mode.binding, mode.consumed);
            gesture.handle(matching(Kind::KeyDown, 100));
            result = gesture.handle(matching(Kind::KeyUp, 150, switchOnRelease ? 20 : 10));
            require(result.consumed == mode.consumed,
                    "an application switch cannot leak an intercepted key-up or consume passive copy");
            require(gesture.handle(matching(Kind::KeyDown, 250, 20)).firstPress,
                    "an application switch disarms the old pair, during or after release");
            gesture.handle(matching(Kind::KeyUp, 270, 20));
            require(gesture.handle(matching(Kind::KeyDown, 300, 20)).triggered,
                    "the new application can form a fresh pair");
        }

        gesture.configure(mode.binding, mode.consumed);
        gesture.handle(matching(Kind::KeyDown, 100));
        gesture.cancel();
        require(gesture.handle(matching(Kind::KeyUp, 150)).consumed == mode.consumed,
                "cancellation retains ownership of intercepted key-up and leaves copy passive");
        require(gesture.handle(matching(Kind::KeyDown, 200)).firstPress, "explicit cancellation disarms");
        gesture.reset();
        require(gesture.handle(matching(Kind::KeyDown, 250)).firstPress, "explicit reset disarms and releases held state");
    }
}

static void testNativeWindowCommands() {
    for (const std::uint16_t key : {0, 6, 7, 8, 9, 13}) {
        require(isNativeWindowShortcut(key, Command), "native editing and Close commands keep window priority");
        require(!isNativeWindowShortcut(key, Option), "Option bindings remain global in the translator");
        require(!isNativeWindowShortcut(key, Command | Option), "extra modifiers preserve custom global bindings");
    }
    require(isNativeWindowShortcut(6, Command | Shift), "native Redo keeps window priority");
    require(!isNativeWindowShortcut(9, Command | Shift), "unrelated shifted bindings remain global");
    require(!isNativeWindowShortcut(17, Option), "default Open Translator remains global in the translator");
    require(!isNativeWindowShortcut(17, Command), "unrelated Command bindings remain global");
}

static void testModifierRelease() {
    ShortcutGesture gesture;
    const auto binding = defaultShortcuts()[1];
    for (auto modifiers : {std::uint8_t(0), std::uint8_t(Option | Shift)}) {
        gesture.configure(binding, true);
        gesture.handle(event(Kind::KeyDown, 100));
        gesture.handle(event(Kind::KeyUp, 150));
        gesture.handle(event(Kind::FlagsChanged, 175, 58, modifiers));
        require(gesture.handle(event(Kind::KeyDown, 250)).firstPress,
                "releasing Option or adding a modifier cancels an intercepted pair");
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

    gesture.configure(defaultShortcuts()[0], false);
    auto result = gesture.handle(event(Kind::KeyDown, 100, 8, Command));
    require(result.firstPress && !result.consumed, "default copy first press stays passive");
    gesture.handle(event(Kind::KeyUp, 150, 8, 0));
    gesture.handle(event(Kind::FlagsChanged, 180, 55, 0));
    result = gesture.handle(event(Kind::KeyDown, 300, 8, Command));
    require(result.triggered && !result.consumed, "Command may be re-pressed between passive copies");
}

static void testSinglePress() {
    ShortcutGesture gesture;
    ShortcutBinding binding{true, 40, std::uint8_t(Control | Option), 1};
    gesture.configure(binding, true);
    auto result = gesture.handle(event(Kind::KeyDown, 100, 40, binding.modifiers));
    require(result.triggered && result.consumed, "arbitrary single chord fires on first down");
    require(!gesture.handle(event(Kind::KeyDown, 200, 40, binding.modifiers, 10, true)).triggered,
            "single chord fires once while held");
    require(gesture.handle(event(Kind::KeyUp, 250, 40, binding.modifiers)).consumed,
            "single chord retains ownership of its release");
    require(gesture.handle(event(Kind::KeyDown, 300, 40, binding.modifiers)).triggered,
            "single chord is available after release");
    binding.enabled = false;
    gesture.configure(binding, true);
    result = gesture.handle(event(Kind::KeyDown, 100, 40, binding.modifiers));
    require(!result.triggered && !result.consumed, "disabled shortcut restores normal typing");
}

static void testMonitorTransitions() {
    using Transition = ShortcutMonitorState::Transition;
    for (const bool suspended : {false, true}) {
        for (const bool configuration : {false, true}) {
            ShortcutMonitorState state;
            if (suspended) state.transition(Transition::Suspend);
            if (configuration) state.transition(Transition::EnterConfiguration);
            require(!state.running() && !state.awake(), "stopped monitor cannot run");
            state.transition(Transition::Wake);
            require(!state.started(), "a wake notification cannot start a stopped monitor");
            state.transition(Transition::Start);
            require(state.running() == (!suspended && !configuration),
                    "start preserves suspension and recording independently");
            require(state.observing() == !suspended,
                    "Settings keeps permission availability live while bypassing actions");
            state.transition(Transition::Sleep);
            state.transition(Transition::Start);
            require(!state.awake() && !state.observing(), "repeated start cannot wake a sleeping monitor");
            state.transition(Transition::Resume);
            state.transition(Transition::LeaveConfiguration);
            require(!state.running(), "clearing both inhibitors cannot wake a sleeping monitor");
            if (suspended) state.transition(Transition::Suspend);
            if (configuration) state.transition(Transition::EnterConfiguration);
            state.transition(Transition::Wake);
            require(state.running() == (!suspended && !configuration), "wake preserves both inhibitors");
            state.transition(Transition::Stop);
            state.transition(Transition::Start);
            require(state.suspended() == suspended && state.configurationActive() == configuration,
                    "stop/start retains independent inhibitors");
            state.transition(Transition::Resume);
            require(state.running() == !configuration, "resuming cannot clear recording");
            state.transition(Transition::LeaveConfiguration);
            require(state.running(), "clearing the last inhibitor restores running");
        }
    }
}

static void testReconfiguredKeyOwnership() {
    ShortcutKeyOwnership keys;
    ShortcutGesture gesture;
    auto binding = defaultShortcuts()[1];
    for (const bool sameKey : {false, true}) {
        keys.reset();
        binding.keyCode = 17;
        binding.pressCount = 2;
        gesture.configure(binding, true);
        require(gesture.handle(event(Kind::KeyDown, 100)).consumed, "old binding captures its first down");
        keys.capture(17);
        keys.awaitCopyRelease(17);
        keys.reconfigure();
        binding.keyCode = sameKey ? 17 : 40;
        binding.pressCount = 1;
        gesture.configure(binding, true);
        auto owned = keys.handle(Kind::KeyDown, 17);
        require(owned.consumed && owned.drainingDown && !owned.copyReleased,
                "reconfiguration drains the held key without allowing a new gesture");
        owned = keys.handle(Kind::KeyUp, 17);
        require(owned.consumed && !owned.copyReleased, "old release drains without completing cancelled copying");
        gesture.handle(event(Kind::KeyUp, 150));
        require(!keys.handle(Kind::KeyUp, 17).consumed && !keys.draining(),
                "an intercepted release is owned exactly once");
        for (unsigned press = 0; press < 3; ++press) {
            const auto down = event(Kind::KeyDown, 200 + press * 100, binding.keyCode);
            require(!keys.handle(down.kind, down.keyCode).drainingDown, "fresh configured key is available");
            const auto result = gesture.handle(down);
            require(result.triggered && result.consumed, "each fresh single press triggers after reconfiguration");
            keys.capture(binding.keyCode);
            require(!gesture.handle(event(Kind::KeyDown, 220 + press * 100, binding.keyCode, Option, 10, true)).triggered,
                    "held repeats cannot dispatch a second action");
            require(keys.handle(Kind::KeyUp, binding.keyCode).consumed, "fresh action owns its release");
            gesture.handle(event(Kind::KeyUp, 250 + press * 100, binding.keyCode));
        }
    }
    keys.capture(17);
    keys.awaitCopyRelease(17);
    require(!keys.handle(Kind::KeyUp, 40).copyReleased, "unrelated release cannot begin copying");
    require(!keys.handle(Kind::FlagsChanged, 17).consumed, "modifier changes do not release an intercepted key");
    require(keys.handle(Kind::KeyUp, 17).copyReleased, "matching release begins deferred copying");
    require(!keys.handle(Kind::KeyUp, 17).copyReleased, "deferred copying starts only once");
    keys.awaitCopyRelease(17);
    require(keys.handle(Kind::KeyDown, 40).copyInterrupted, "another down cancels deferred copying");
    require(!keys.handle(Kind::KeyUp, 17).copyReleased, "interrupted copy cannot complete on late release");
    keys.capture(17);
    keys.capture(40);
    keys.reconfigure();
    keys.reconcile([](unsigned key) { return key == 40; });
    require(!keys.handle(Kind::KeyDown, 17).consumed, "a missed physical release cannot consume the next unrelated press");
    require(keys.handle(Kind::KeyUp, 40).consumed, "reconciliation preserves a physically held key");
    keys.capture(17);
    keys.awaitCopyRelease(17);
    keys.reset();
    require(!keys.draining() && !keys.handle(Kind::KeyUp, 17).copyReleased,
            "stop, sleep and permission loss discard ownership and deferred copy together");
}

int main() {
    testBindings();
    testNativeWindowCommands();
    testDoublePress();
    testModifierRelease();
    testSinglePress();
    testMonitorTransitions();
    testReconfiguredKeyOwnership();
    std::cout << "Shortcut binding and gesture tests passed\n";
}
