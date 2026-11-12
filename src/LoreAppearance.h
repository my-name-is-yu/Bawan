#import <AppKit/AppKit.h>

// A darker shade of the icon's vermilion keeps white button labels readable.
static inline NSColor *LoreAccentFillColor(void) {
    return [NSColor colorWithSRGBRed:200.0 / 255.0 green:63.0 / 255.0
                              blue:40.0 / 255.0 alpha:1.0];
}

static inline NSColor *LoreAccentColor(void) {
    return [NSColor colorWithName:@"LoreAccent" dynamicProvider:^NSColor *(NSAppearance *appearance) {
        NSString *match = [appearance bestMatchFromAppearancesWithNames:
            @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        if ([match isEqualToString:NSAppearanceNameDarkAqua]) {
            return [NSColor colorWithSRGBRed:1.0 green:121.0 / 255.0
                                      blue:94.0 / 255.0 alpha:1.0];
        }
        return LoreAccentFillColor();
    }];
}
