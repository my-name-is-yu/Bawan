#include "ShortcutBinding.h"

namespace bawan {
namespace {
bool unresolvedCommandKey(std::uint16_t key, std::uint8_t modifiers, const KeyboardLayout& layout) {
    if (key > 50 || key == 36 || key == 48 || key == 49) return false;
    const auto layer = modifiers == Command ? KeyboardLayer::Command : KeyboardLayer::CommandShift;
    return !layout.character(key, layer);
}
}

ShortcutBindings defaultShortcuts(const KeyboardLayout& layout) {
    const auto copy = layout.copyKey();
    return {{{copy.has_value(), copy.value_or(unresolvedShortcutKey), Command, 2}, {true, 17, Option, 2}}};
}

bool isPassiveCopy(const ShortcutBinding& binding, const KeyboardLayout& layout) {
    return layout.matches(binding.keyCode, KeyboardLayer::Command, u'c') &&
        binding.modifiers == Command && binding.pressCount == 2;
}

bool isNativeWindowShortcut(std::uint16_t keyCode, std::uint8_t modifiers, const KeyboardLayout& layout) {
    if ((modifiers == Command || modifiers == (Command | Shift)) &&
        unresolvedCommandKey(keyCode, modifiers, layout)) return true;
    if (modifiers == (Command | Shift)) return layout.matches(keyCode, KeyboardLayer::CommandShift, u'z');
    if (modifiers != Command) return false;
    for (const auto c : u"azxcvw") if (c && layout.matches(keyCode, KeyboardLayer::Command, c)) return true;
    return false;
}

bool isReservedShortcut(std::uint16_t keyCode, std::uint8_t modifiers, const KeyboardLayout& layout) {
    if ((modifiers == Command || modifiers == (Command | Shift)) &&
        unresolvedCommandKey(keyCode, modifiers, layout)) return true;
    if (modifiers == Command) {
        return keyCode == 36 || keyCode == 76 || layout.matches(keyCode, KeyboardLayer::Command, u'q') ||
            layout.matches(keyCode, KeyboardLayer::Command, u',');
    }
    return modifiers == (Command | Shift) && layout.matches(keyCode, KeyboardLayer::CommandShift, u'c');
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

ShortcutError validateShortcut(const ShortcutBinding& binding) {
    if (!isShortcutKey(binding.keyCode) && (binding.enabled || binding.keyCode != unresolvedShortcutKey)) return ShortcutError::InvalidKey;
    constexpr std::uint8_t primaryModifiers = Command | Option | Control;
    constexpr std::uint8_t allowedModifiers = primaryModifiers | Shift;
    if (!(binding.modifiers & primaryModifiers) || (binding.modifiers & ~allowedModifiers)) {
        return ShortcutError::MissingModifier;
    }
    if (binding.pressCount != 1 && binding.pressCount != 2) return ShortcutError::InvalidPressCount;
    return ShortcutError::None;
}

ShortcutError validateShortcut(const ShortcutBinding& binding, const KeyboardLayout& layout) {
    const auto error = validateShortcut(binding);
    if (error != ShortcutError::None) return error;
    return binding.enabled && isReservedShortcut(binding.keyCode, binding.modifiers, layout) ? ShortcutError::Reserved : ShortcutError::None;
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

ShortcutError validateShortcuts(const ShortcutBindings& bindings, const KeyboardLayout& layout) {
    for (const auto& binding : bindings) {
        const auto error = validateShortcut(binding, layout);
        if (error != ShortcutError::None) return error;
    }
    return validateShortcuts(bindings);
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
        if (suppress_ && event.modifiers != binding_.modifiers) cancel();
        return result;
    }
    if (event.kind == ShortcutEvent::Kind::KeyUp) {
        if (event.keyCode == binding_.keyCode) {
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

}
