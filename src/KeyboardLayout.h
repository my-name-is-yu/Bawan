#pragma once

#include <array>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>

namespace bawan {

enum class KeyboardLayer { Plain, Command, CommandShift };
struct KeyTranslation {
    std::u16string text;
    bool deadKey = false;
};

// A snapshot of actual key-down translations, with fresh dead-key state per key.
struct KeyboardLayout {
    using Keys = std::array<char16_t, 128>;
    Keys plain{}, command{}, commandShift{};
    char16_t character(std::uint16_t key, KeyboardLayer layer) const;
    bool matches(std::uint16_t key, KeyboardLayer layer, char16_t character) const;
    std::optional<std::uint16_t> copyKey() const;
};
inline bool operator==(const KeyboardLayout& a, const KeyboardLayout& b) {
    return a.plain == b.plain && a.command == b.command && a.commandShift == b.commandShift;
}
inline bool operator!=(const KeyboardLayout& a, const KeyboardLayout& b) { return !(a == b); }
KeyboardLayout readKeyboardLayout(const std::function<KeyTranslation(std::uint16_t, KeyboardLayer)>& translate);
bool isShortcutKey(std::uint16_t key);

}
