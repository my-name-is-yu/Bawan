#pragma once
#include <array>
#include <cstdint>

namespace lore {
enum class ShortcutAction : unsigned { TranslateSelection = 0, OpenPanel = 1 };
enum ShortcutModifier : std::uint8_t { Command = 1, Option = 2, Control = 4, Shift = 8, Function = 16 };
struct ShortcutBinding {
    bool enabled = true;
    std::uint16_t keyCode = 8;
    std::uint8_t modifiers = Command;
    std::uint8_t pressCount = 2;
};
using ShortcutBindings = std::array<ShortcutBinding, 2>;
enum class ShortcutError { None, InvalidKey, MissingModifier, InvalidPressCount, Reserved, Duplicate };
ShortcutBindings defaultShortcuts();
bool isPassiveCopy(const ShortcutBinding& binding);
// macOS marks function/navigation keys with Fn even without a held Fn key.
std::uint8_t normalizeShortcutModifiers(std::uint8_t modifiers, std::uint16_t keyCode);
ShortcutError validateShortcut(const ShortcutBinding& binding);
ShortcutError validateShortcuts(const ShortcutBindings& bindings);
struct ShortcutEvent {
    enum class Kind { KeyDown, KeyUp, FlagsChanged };
    Kind kind;
    std::uint16_t keyCode;
    std::uint8_t modifiers;
    bool repeat;
    std::int64_t application;
    std::uint64_t timeNanoseconds;
};
class ShortcutGesture {
public:
    struct Result {
        bool firstPress = false;
        bool triggered = false;
        bool consumed = false;
        bool released = false;
    };
    void configure(ShortcutBinding binding, bool suppress);
    Result handle(const ShortcutEvent& event);
    // Cancel a gesture but retain ownership of a swallowed key until release.
    void cancel();
    void reset();
private:
    ShortcutBinding binding_;
    bool suppress_ = false;
    bool down_ = false;
    bool consumedDown_ = false;
    bool armed_ = false;
    std::int64_t application_ = 0;
    std::uint64_t firstTime_ = 0;
};
} // namespace lore
