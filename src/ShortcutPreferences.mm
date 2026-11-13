#import "ShortcutPreferences.h"
#import <Carbon/Carbon.h>

#include <cmath>

NSNotificationName const BawanShortcutsDidChangeNotification = @"BawanShortcutsDidChange";
static NSString *const PreferencesKey = @"globalShortcuts";

static NSString *ActionKey(bawan::ShortcutAction action) {
    return action == bawan::ShortcutAction::TranslateSelection ? @"translateSelection" : @"openPanel";
}

NSString *ShortcutActionTitle(bawan::ShortcutAction action) {
    return action == bawan::ShortcutAction::TranslateSelection ? @"Translate Selection" : @"Open Translator";
}

static NSString *SpecialKeyLabel(std::uint16_t key) {
    switch (key) {
        case 36: return @"↩";
        case 48: return @"⇥";
        case 49: return @"Space";
        case 51: return @"⌫";
        case 53: return @"Esc";
        case 65: return @"Num .";
        case 67: return @"Num *";
        case 69: return @"Num +";
        case 71: return @"Clear";
        case 75: return @"Num /";
        case 76: return @"⌤";
        case 78: return @"Num −";
        case 81: return @"Num =";
        case 82: return @"Num 0";
        case 83: return @"Num 1";
        case 84: return @"Num 2";
        case 85: return @"Num 3";
        case 86: return @"Num 4";
        case 87: return @"Num 5";
        case 88: return @"Num 6";
        case 89: return @"Num 7";
        case 91: return @"Num 8";
        case 92: return @"Num 9";
        case 95: return @"Num ,";
        case 64: return @"F17";
        case 79: return @"F18";
        case 80: return @"F19";
        case 90: return @"F20";
        case 96: return @"F5";
        case 97: return @"F6";
        case 98: return @"F7";
        case 99: return @"F3";
        case 100: return @"F8";
        case 101: return @"F9";
        case 103: return @"F11";
        case 105: return @"F13";
        case 106: return @"F16";
        case 107: return @"F14";
        case 109: return @"F10";
        case 111: return @"F12";
        case 113: return @"F15";
        case 114: return @"Help";
        case 115: return @"Home";
        case 116: return @"Page Up";
        case 117: return @"⌦";
        case 118: return @"F4";
        case 119: return @"End";
        case 120: return @"F2";
        case 121: return @"Page Down";
        case 122: return @"F1";
        case 123: return @"←";
        case 124: return @"→";
        case 125: return @"↓";
        case 126: return @"↑";
        default: return nil;
    }
}

static NSString *LayoutKeyLabel(std::uint16_t key) {
    TISInputSourceRef source = TISCopyCurrentKeyboardLayoutInputSource();
    if (!source) return nil;
    CFDataRef data = static_cast<CFDataRef>(TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData));
    NSString *label = nil;
    if (data) {
        const UCKeyboardLayout *layout = reinterpret_cast<const UCKeyboardLayout *>(CFDataGetBytePtr(data));
        UInt32 deadKeys = 0;
        UniChar characters[8];
        UniCharCount length = 0;
        OSStatus status = UCKeyTranslate(layout, key, kUCKeyActionDisplay, 0, LMGetKbdType(),
                                         kUCKeyTranslateNoDeadKeysMask, &deadKeys, 8, &length, characters);
        if (status == noErr && length > 0) {
            NSString *candidate = [NSString stringWithCharacters:characters length:length];
            if ([candidate rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound) {
                label = candidate.uppercaseString;
            }
        }
    }
    CFRelease(source);
    return label;
}

NSString *ShortcutKeyLabel(bawan::ShortcutBinding binding) {
    NSMutableString *label = [NSMutableString string];
    if (binding.modifiers & bawan::Control) [label appendString:@"⌃"];
    if (binding.modifiers & bawan::Option) [label appendString:@"⌥"];
    if (binding.modifiers & bawan::Shift) [label appendString:@"⇧"];
    if (binding.modifiers & bawan::Command) [label appendString:@"⌘"];
    NSString *key = SpecialKeyLabel(binding.keyCode) ?: LayoutKeyLabel(binding.keyCode);
    [label appendString:key ?: [NSString stringWithFormat:@"Key %u", static_cast<unsigned>(binding.keyCode)]];
    return label;
}

NSString *ShortcutBindingLabel(bawan::ShortcutBinding binding) {
    return [NSString stringWithFormat:@"%@ ×%u", ShortcutKeyLabel(binding), static_cast<unsigned>(binding.pressCount)];
}

std::uint8_t ShortcutModifiersFromFlags(NSEventModifierFlags flags, std::uint16_t keyCode) {
    std::uint8_t result = 0;
    if (flags & NSEventModifierFlagCommand) result |= bawan::Command;
    if (flags & NSEventModifierFlagOption) result |= bawan::Option;
    if (flags & NSEventModifierFlagControl) result |= bawan::Control;
    if (flags & NSEventModifierFlagShift) result |= bawan::Shift;
    if (flags & NSEventModifierFlagFunction) result |= bawan::Function;
    return bawan::normalizeShortcutModifiers(result, keyCode);
}

static bool ReadInteger(id value, unsigned maximum, unsigned &result) {
    if (![value isKindOfClass:NSNumber.class]) return false;
    double number = [value doubleValue];
    if (!std::isfinite(number) || number < 0 || number > maximum || std::floor(number) != number) return false;
    result = static_cast<unsigned>(number);
    return true;
}

static bool ReadBinding(id value, bawan::ShortcutBinding &binding) {
    if (![value isKindOfClass:NSDictionary.class]) return false;
    unsigned enabled, key, modifiers, count;
    if (!ReadInteger(value[@"enabled"], 1, enabled) ||
        !ReadInteger(value[@"keyCode"], UINT16_MAX, key) ||
        !ReadInteger(value[@"modifiers"], UINT8_MAX, modifiers) ||
        !ReadInteger(value[@"pressCount"], 2, count)) return false;
    bawan::ShortcutBinding candidate{enabled != 0, static_cast<std::uint16_t>(key),
        static_cast<std::uint8_t>(modifiers), static_cast<std::uint8_t>(count)};
    if (bawan::validateShortcut(candidate) != bawan::ShortcutError::None) return false;
    binding = candidate;
    return true;
}

static NSDictionary *EncodeBinding(bawan::ShortcutBinding binding) {
    return @{@"enabled": @(binding.enabled), @"keyCode": @(binding.keyCode),
             @"modifiers": @(binding.modifiers), @"pressCount": @(binding.pressCount)};
}

static bool EqualBindings(bawan::ShortcutBinding lhs, bawan::ShortcutBinding rhs) {
    return lhs.enabled == rhs.enabled && lhs.keyCode == rhs.keyCode &&
        lhs.modifiers == rhs.modifiers && lhs.pressCount == rhs.pressCount;
}

@interface ShortcutPreferences () {
    NSUserDefaults *_defaults;
    bawan::ShortcutBindings _bindings;
}
@end

@implementation ShortcutPreferences

- (instancetype)init {
    return [self initWithDefaults:NSUserDefaults.standardUserDefaults];
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    self = [super init];
    if (!self) return nil;
    _defaults = defaults;
    _bindings = bawan::defaultShortcuts();
    id stored = [_defaults objectForKey:PreferencesKey];
    if ([stored isKindOfClass:NSDictionary.class]) {
        unsigned version = 0;
        id rows = stored[@"bindings"];
        if (ReadInteger(stored[@"version"], 1, version) && version == 1 && [rows isKindOfClass:NSDictionary.class]) {
            ReadBinding(rows[@"translateSelection"], _bindings[0]);
            ReadBinding(rows[@"openPanel"], _bindings[1]);
        }
    }
    // Corrupt or manually edited preferences must not reserve a chord twice.
    if (bawan::validateShortcuts(_bindings) == bawan::ShortcutError::Duplicate) _bindings[1].enabled = false;
    [self save];
    return self;
}

- (void)save {
    [_defaults setObject:@{@"version": @1, @"bindings": @{
        ActionKey(bawan::ShortcutAction::TranslateSelection): EncodeBinding(_bindings[0]),
        ActionKey(bawan::ShortcutAction::OpenPanel): EncodeBinding(_bindings[1])}}
        forKey:PreferencesKey];
}

- (bawan::ShortcutBindings)bindings { return _bindings; }

- (bawan::ShortcutBinding)bindingForAction:(bawan::ShortcutAction)action {
    return _bindings.at(static_cast<unsigned>(action));
}

- (BOOL)setBinding:(bawan::ShortcutBinding)binding forAction:(bawan::ShortcutAction)action
             error:(NSString **)error {
    NSAssert(NSThread.isMainThread, @"Shortcut settings run on the main thread");
    if (error) *error = nil;
    unsigned index = static_cast<unsigned>(action);
    if (index >= _bindings.size()) {
        if (error) *error = @"Unable to identify this shortcut action.";
        return NO;
    }
    bawan::ShortcutBindings candidate = _bindings;
    candidate[index] = binding;
    bawan::ShortcutError problem = bawan::validateShortcuts(candidate);
    if (problem != bawan::ShortcutError::None) {
        if (error) {
            switch (problem) {
                case bawan::ShortcutError::InvalidKey:
                    *error = @"Choose a standard key, such as a letter, number, punctuation, navigation key, or F1–F20.";
                    break;
                case bawan::ShortcutError::MissingModifier:
                    *error = @"Include ⌘, ⌃, or ⌥. Fn cannot be used.";
                    break;
                case bawan::ShortcutError::InvalidPressCount:
                    *error = @"Choose one or two presses.";
                    break;
                case bawan::ShortcutError::Reserved:
                    *error = @"Bawan already uses this combination. Choose a different shortcut.";
                    break;
                case bawan::ShortcutError::Duplicate: {
                    bawan::ShortcutAction other = index == 0 ? bawan::ShortcutAction::OpenPanel : bawan::ShortcutAction::TranslateSelection;
                    *error = [NSString stringWithFormat:@"This shortcut is already used by “%@”. One-press and two-press shortcuts cannot share the same key combination.", ShortcutActionTitle(other)];
                    break;
                }
                case bawan::ShortcutError::None: break;
            }
        }
        return NO;
    }
    if (EqualBindings(_bindings[index], binding)) return YES;
    _bindings = candidate;
    [self save];
    [NSNotificationCenter.defaultCenter postNotificationName:BawanShortcutsDidChangeNotification object:self];
    return YES;
}

- (BOOL)restoreAction:(bawan::ShortcutAction)action error:(NSString **)error {
    unsigned index = static_cast<unsigned>(action);
    if (index >= _bindings.size()) return NO;
    return [self setBinding:bawan::defaultShortcuts()[index] forAction:action error:error];
}

@end
