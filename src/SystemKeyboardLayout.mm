#import "SystemKeyboardLayout.h"
#import <Foundation/Foundation.h>

static bawan::KeyboardLayout TranslateLayout(CFDataRef data, UInt32 keyboardType) {
    if (!data || CFDataGetLength(data) < static_cast<CFIndex>(sizeof(UCKeyboardLayout))) return {};
    const auto* layout = reinterpret_cast<const UCKeyboardLayout*>(CFDataGetBytePtr(data));
    return bawan::readKeyboardLayout([&](std::uint16_t key, bawan::KeyboardLayer layer) {
        const UInt32 modifiers = layer == bawan::KeyboardLayer::Plain ? 0 :
            layer == bawan::KeyboardLayer::Command ? cmdKey : cmdKey | shiftKey;
        UInt32 deadState = 0;
        UniChar characters[8];
        UniCharCount length = 0;
        const OSStatus status = UCKeyTranslate(layout, key, kUCKeyActionDown, modifiers >> 8,
            keyboardType, 0, &deadState, 8, &length, characters);
        if (status != noErr) return bawan::KeyTranslation{};
        return bawan::KeyTranslation{std::u16string(characters, characters + length), deadState != 0};
    });
}

bawan::KeyboardLayout KeyboardLayoutForInputSource(TISInputSourceRef source, UInt32 keyboardType) {
    NSCAssert(NSThread.isMainThread, @"Keyboard layout APIs run on the main thread");
    if (!source) return {};
    const auto data = static_cast<CFDataRef>(TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData));
    return TranslateLayout(data, keyboardType);
}

bawan::KeyboardLayout CurrentKeyboardLayout() {
    NSCAssert(NSThread.isMainThread, @"Keyboard layout APIs run on the main thread");
    // This returns an IME's effective underlying layout. An ASCII-capable source
    // can differ from an IME override, so missing data must not guess a fallback.
    TISInputSourceRef source = TISCopyCurrentKeyboardLayoutInputSource();
    CFDataRef data = source ? static_cast<CFDataRef>(
        TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)) : nullptr;
    const UInt32 keyboardType = LMGetKbdType();
    static NSData* previousData;
    static UInt32 previousType = UINT32_MAX;
    static bawan::KeyboardLayout previousLayout;
    NSData* currentData = (__bridge NSData*)data;
    if (previousType != keyboardType || ![previousData isEqualToData:currentData]) {
        previousLayout = TranslateLayout(data, keyboardType);
        previousData = [currentData copy];
        previousType = keyboardType;
    }
    if (source) CFRelease(source);
    return previousLayout;
}
