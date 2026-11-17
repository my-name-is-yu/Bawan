#include "KeyboardLayout.h"

namespace bawan {
namespace {
char16_t lowerASCII(char16_t c) { return c >= u'A' && c <= u'Z' ? c + (u'a' - u'A') : c; }
}

char16_t KeyboardLayout::character(std::uint16_t key, KeyboardLayer layer) const {
    if (key >= plain.size()) return 0;
    return (layer == KeyboardLayer::Command ? command :
        layer == KeyboardLayer::CommandShift ? commandShift : plain)[key];
}

bool KeyboardLayout::matches(std::uint16_t key, KeyboardLayer layer, char16_t c) const {
    return lowerASCII(character(key, layer)) == lowerASCII(c);
}

std::optional<std::uint16_t> KeyboardLayout::copyKey() const {
    std::optional<std::uint16_t> result;
    for (std::uint16_t key = 0; key < command.size(); ++key) {
        if (!isShortcutKey(key) || !matches(key, KeyboardLayer::Command, u'c')) continue;
        if (result) return std::nullopt;
        result = key;
    }
    return result;
}

bool isShortcutKey(std::uint16_t key) {
    if (key <= 51 || key == 53 || (key >= 82 && key <= 101) ||
        (key >= 114 && key <= 126)) return true;
    switch (key) {
        case 64: case 65: case 67: case 69: case 71: case 75: case 76:
        case 78: case 79: case 80: case 81: case 103: case 105: case 106:
        case 107: case 109: case 111: case 113:
            return true;
        default:
            return false;
    }
}

KeyboardLayout readKeyboardLayout(const std::function<KeyTranslation(std::uint16_t, KeyboardLayer)>& translate) {
    KeyboardLayout result;
    for (auto layer : {KeyboardLayer::Plain, KeyboardLayer::Command, KeyboardLayer::CommandShift}) {
        auto& keys = layer == KeyboardLayer::Plain ? result.plain :
            layer == KeyboardLayer::Command ? result.command : result.commandShift;
        for (std::uint16_t key = 0; key < keys.size(); ++key) {
            const auto value = translate(key, layer);
            if (value.deadKey || value.text.size() != 1) continue;
            const auto c = value.text[0];
            if (c < 0x20 || (c >= 0x7f && c <= 0x9f) || (c >= 0xd800 && c <= 0xdfff)) continue;
            keys[key] = c;
        }
    }
    return result;
}

}
