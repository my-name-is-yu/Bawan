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

static NSString *LayoutKeyLabel(bawan::ShortcutBinding binding, const bawan::KeyboardLayout& layout) {
    const auto layer = !(binding.modifiers & bawan::Command) ? bawan::KeyboardLayer::Plain :
        binding.modifiers & bawan::Shift ? bawan::KeyboardLayer::CommandShift : bawan::KeyboardLayer::Command;
    const unichar character = layout.character(binding.keyCode, layer);
    return character ? [NSString stringWithCharacters:&character length:1].uppercaseString : nil;
}

NSString *ShortcutKeyLabel(bawan::ShortcutBinding binding) {
    return ShortcutKeyLabel(binding, CurrentKeyboardLayout());
}

NSString *ShortcutKeyLabel(bawan::ShortcutBinding binding, const bawan::KeyboardLayout& layout) {
    if (binding.keyCode == bawan::unresolvedShortcutKey) return @"Unavailable";
    NSMutableString *label = [NSMutableString string];
    if (binding.modifiers & bawan::Control) [label appendString:@"⌃"];
    if (binding.modifiers & bawan::Option) [label appendString:@"⌥"];
    if (binding.modifiers & bawan::Shift) [label appendString:@"⇧"];
    if (binding.modifiers & bawan::Command) [label appendString:@"⌘"];
    NSString *key = SpecialKeyLabel(binding.keyCode) ?: LayoutKeyLabel(binding, layout);
    [label appendString:key ?: [NSString stringWithFormat:@"Key %u", static_cast<unsigned>(binding.keyCode)]];
    return label;
}

bawan::ShortcutBindings ShortcutDefaultBindings() { return bawan::defaultShortcuts(CurrentKeyboardLayout()); }
bool ShortcutIsPassiveCopy(bawan::ShortcutBinding binding) { return bawan::isPassiveCopy(binding, CurrentKeyboardLayout()); }

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

@interface ShortcutPreferences () {
    NSUserDefaults *_defaults;
    bawan::ShortcutBindings _bindings;
    bawan::KeyboardLayout (^_layoutProvider)(void);
    id _layoutObserver;
}
@end

@implementation ShortcutPreferences

- (instancetype)init {
    return [self initWithDefaults:NSUserDefaults.standardUserDefaults];
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    return [self initWithDefaults:defaults layoutProvider:^{ return CurrentKeyboardLayout(); }];
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults layoutProvider:(bawan::KeyboardLayout (^)(void))provider {
    self = [super init];
    if (!self) return nil;
    _defaults = defaults;
    _layoutProvider = [provider copy];
    _bindings = bawan::defaultShortcuts({});
    id stored = [_defaults objectForKey:PreferencesKey];
    if ([stored isKindOfClass:NSDictionary.class]) {
        unsigned version = 0;
        id rows = stored[@"bindings"];
        if (ReadInteger(stored[@"version"], 1, version) && version == 1 && [rows isKindOfClass:NSDictionary.class]) {
            ReadBinding(rows[@"translateSelection"], _bindings[0]);
            ReadBinding(rows[@"openPanel"], _bindings[1]);
        }
    }
    if (![self resolveDefaultSelection] &&
        bawan::validateShortcuts(_bindings) == bawan::ShortcutError::Duplicate) _bindings[1].enabled = false;
    [self save];
    __weak ShortcutPreferences *weakSelf = self;
    _layoutObserver = [NSDistributedNotificationCenter.defaultCenter
        addObserverForName:(__bridge NSString *)kTISNotifySelectedKeyboardInputSourceChanged object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *) {
            ShortcutPreferences *self = weakSelf;
            if (self) [NSNotificationCenter.defaultCenter postNotificationName:BawanShortcutsDidChangeNotification object:self];
        }];
    return self;
}

- (void)dealloc {
    if (_layoutObserver) [NSDistributedNotificationCenter.defaultCenter removeObserver:_layoutObserver];
}

- (bawan::KeyboardLayout)keyboardLayout { return _layoutProvider(); }

- (BOOL)resolveDefaultSelection {
    if (_bindings[0].keyCode != bawan::unresolvedShortcutKey) return NO;
    const auto selection = bawan::defaultShortcuts(self.keyboardLayout)[0];
    if (!selection.enabled) return NO;
    _bindings[0] = selection;
    if (bawan::validateShortcuts(_bindings) == bawan::ShortcutError::Duplicate) _bindings[0].enabled = false;
    return YES;
}

- (void)save {
    NSMutableDictionary *rows = [@{
        ActionKey(bawan::ShortcutAction::OpenPanel): EncodeBinding(_bindings[1])} mutableCopy];
    if (_bindings[0].keyCode != bawan::unresolvedShortcutKey) {
        rows[ActionKey(bawan::ShortcutAction::TranslateSelection)] = EncodeBinding(_bindings[0]);
    }
    [_defaults setObject:@{@"version": @1, @"bindings": rows} forKey:PreferencesKey];
}

- (bawan::ShortcutBindings)bindings {
    if ([self resolveDefaultSelection]) [self save];
    return _bindings;
}

- (bawan::ShortcutBinding)bindingForAction:(bawan::ShortcutAction)action {
    const unsigned index = static_cast<unsigned>(action);
    if (index >= _bindings.size()) {
        bawan::ShortcutBinding none;
        none.enabled = false;
        return none;
    }
    return self.bindings[index];
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
    bawan::ShortcutBindings candidate = self.bindings;
    candidate[index] = binding;
    bawan::ShortcutError problem = bawan::validateShortcut(binding, self.keyboardLayout);
    if (problem == bawan::ShortcutError::None) problem = bawan::validateShortcuts(candidate);
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
    if (_bindings[index] == binding) return YES;
    _bindings = candidate;
    [self save];
    [NSNotificationCenter.defaultCenter postNotificationName:BawanShortcutsDidChangeNotification object:self];
    return YES;
}

- (BOOL)restoreAction:(bawan::ShortcutAction)action error:(NSString **)error {
    unsigned index = static_cast<unsigned>(action);
    if (index >= _bindings.size()) return NO;
    return [self setBinding:bawan::defaultShortcuts(self.keyboardLayout)[index] forAction:action error:error];
}

@end
