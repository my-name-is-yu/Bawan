#include "ShortcutBinding.h"

namespace lore {

ShortcutBindings defaultShortcuts() {
    return {{{true, 8, Command, 2}, {true, 17, Option, 2}}};
}

bool isPassiveCopy(const ShortcutBinding& binding) {
    return binding.keyCode == 8 && binding.modifiers == Command && binding.pressCount == 2;
}

std::uint8_t normalizeShortcutModifiers(std::uint8_t modifiers, std::uint16_t keyCode) {
    switch (keyCode) {
        case 64: case 79: case 80: case 90: case 96: case 97: case 98:
        case 99: case 100: case 101: case 103: case 105: case 106:
        case 107: case 109: case 111: case 113: case 114: case 115:
        case 116: case 117: case 118: case 119: case 120: case 121:
        case 122: case 123: case 124: case 125: case 126:
            return static_cast<std::uint8_t>(modifiers & ~Function);
        default:
            return modifiers;
    }
}

static bool supportedKey(std::uint16_t key) {
    // ANSI/ISO/JIS typing keys, keypad, navigation, and F1–F20. Modifier,
    // input-source, media, and hardware-control keys are not shortcut keys.
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

ShortcutError validateShortcut(const ShortcutBinding& binding) {
    if (!supportedKey(binding.keyCode)) return ShortcutError::InvalidKey;
    constexpr std::uint8_t primaryModifiers = Command | Option | Control;
    constexpr std::uint8_t allowedModifiers = primaryModifiers | Shift;
    if (!(binding.modifiers & primaryModifiers) || (binding.modifiers & ~allowedModifiers)) {
        return ShortcutError::MissingModifier;
    }
    if (binding.pressCount != 1 && binding.pressCount != 2) return ShortcutError::InvalidPressCount;
    if ((binding.modifiers == Command &&
         (binding.keyCode == 36 || binding.keyCode == 76 || binding.keyCode == 12 || binding.keyCode == 43)) ||
        (binding.modifiers == (Command | Shift) && binding.keyCode == 8)) {
        return ShortcutError::Reserved;
    }
    return ShortcutError::None;
}

ShortcutError validateShortcuts(const ShortcutBindings& bindings) {
    for (const auto& binding : bindings) {
        const auto error = validateShortcut(binding);
        if (error != ShortcutError::None) return error;
    }
    if (bindings[0].enabled && bindings[1].enabled &&
        bindings[0].keyCode == bindings[1].keyCode &&
        bindings[0].modifiers == bindings[1].modifiers) return ShortcutError::Duplicate;
    return ShortcutError::None;
}

void ShortcutGesture::configure(ShortcutBinding binding, bool suppress) {
    reset();
    binding_ = binding;
    suppress_ = suppress;
}

ShortcutGesture::Result ShortcutGesture::handle(const ShortcutEvent& event) {
    Result result;
    if (event.application != application_) {
        cancel();
        application_ = event.application;
    }
    if (event.kind == ShortcutEvent::Kind::FlagsChanged) {
        // Copy remains passive and supports releasing Command between copies.
        if (suppress_ && event.modifiers != binding_.modifiers) cancel();
        return result;
    }
    if (event.kind == ShortcutEvent::Kind::KeyUp) {
        if (event.keyCode == binding_.keyCode) {
            result.released = down_;
            result.consumed = consumedDown_;
            down_ = false;
            consumedDown_ = false;
            if (suppress_ && event.modifiers != binding_.modifiers) cancel();
        }
        return result;
    }
    if (!binding_.enabled) return result;
    if (event.keyCode != binding_.keyCode) {
        cancel();
        return result;
    }
    if (down_) {
        // A swallowed press retains ownership even if Option is released or
        // another modifier is pressed before key-up.
        result.consumed = consumedDown_;
        if (event.repeat || event.modifiers != binding_.modifiers) cancel();
        return result;
    }
    down_ = true;
    if (event.repeat || event.modifiers != binding_.modifiers) {
        cancel();
        return result;
    }
    consumedDown_ = suppress_;
    result.consumed = consumedDown_;
    if (binding_.pressCount == 1) {
        result.firstPress = true;
        result.triggered = true;
        armed_ = false;
        return result;
    }
    constexpr std::uint64_t interval = 400'000'000;
    if (armed_ && event.timeNanoseconds >= firstTime_ &&
        event.timeNanoseconds - firstTime_ <= interval) {
        armed_ = false;
        result.triggered = true;
    } else {
        armed_ = true;
        firstTime_ = event.timeNanoseconds;
        result.firstPress = true;
    }
    return result;
}

void ShortcutGesture::cancel() {
    armed_ = false;
    firstTime_ = 0;
}

void ShortcutGesture::reset() {
    down_ = false;
    consumedDown_ = false;
    application_ = 0;
    cancel();
}

} // namespace lore
