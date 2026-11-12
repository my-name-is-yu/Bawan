#pragma once
#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, LoreColorRole) {
    LoreBackground, LoreSurface, LoreText, LoreSecondaryText, LoreBorder,
    LoreButton, LoreHeader, LoreHeaderText, LoreGold, LoreGoldText, LoreSuccess, LoreError
};

static inline NSColor *LoreRGB(unsigned value) {
    return [NSColor colorWithSRGBRed:((value >> 16) & 255) / 255.0
                              green:((value >> 8) & 255) / 255.0
                               blue:(value & 255) / 255.0 alpha:1];
}

static inline NSColor *LoreColor(LoreColorRole role) {
    static NSArray<NSColor *> *palette;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const unsigned light[] = {
            0xF7E7BB, 0xFFF1CE, 0x443024, 0x72543B, 0x624530, 0xF2DBA8,
            0xB53B28, 0xF7E7BB, 0xD99E3D, 0x443024, 0x35603B, 0xB53B28
        };
        const unsigned dark[] = {
            0x28211C, 0x332821, 0xF5E6C8, 0xC9B594, 0xA88150, 0x493725,
            0x7B2D20, 0xF5E6C8, 0xC99B53, 0x28211C, 0x9BC29A, 0xF08A63
        };
        NSMutableArray<NSColor *> *colors = [NSMutableArray array];
        for (NSUInteger i = 0; i < sizeof(light) / sizeof(light[0]); ++i) {
            NSColor *lightColor = LoreRGB(light[i]);
            NSColor *darkColor = LoreRGB(dark[i]);
            NSColor *contrastLight = (i == LoreBorder || i == LoreSecondaryText) ?
                LoreRGB(0x443024) : lightColor;
            NSColor *contrastDark = (i == LoreBorder || i == LoreSecondaryText) ?
                LoreRGB(0xF5E6C8) : darkColor;
            [colors addObject:[NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
                NSString *match = [appearance bestMatchFromAppearancesWithNames:@[
                    NSAppearanceNameAccessibilityHighContrastAqua,
                    NSAppearanceNameAccessibilityHighContrastDarkAqua,
                    NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
                if ([match isEqualToString:NSAppearanceNameAccessibilityHighContrastAqua]) return contrastLight;
                if ([match isEqualToString:NSAppearanceNameAccessibilityHighContrastDarkAqua]) return contrastDark;
                return [match isEqualToString:NSAppearanceNameDarkAqua] ? darkColor : lightColor;
            }]];
        }
        palette = [colors copy];
    });
    return palette[role];
}

static inline NSColor *LoreAccentFillColor(void) { return LoreRGB(0xB53B28); }
static inline NSColor *LoreAccentColor(void) { return LoreColor(LoreError); }

static inline NSFont *LoreSerifFont(CGFloat size, BOOL bold) {
    NSFont *latin = [NSFont fontWithName:bold ? @"Georgia-Bold" : @"Georgia" size:size];
    if (!latin) latin = [NSFont systemFontOfSize:size weight:bold ? NSFontWeightSemibold : NSFontWeightRegular];
    NSFontDescriptor *japanese = [NSFontDescriptor fontDescriptorWithName:
        bold ? @"HiraMinProN-W6" : @"HiraMinProN-W3" size:size];
    NSFontDescriptor *descriptor = [latin.fontDescriptor fontDescriptorByAddingAttributes:
        @{NSFontCascadeListAttribute: @[japanese]}];
    return [NSFont fontWithDescriptor:descriptor size:size] ?: latin;
}

static inline NSFont *LoreBodyFont(CGFloat size) { return LoreSerifFont(size, NO); }
static inline NSFont *LoreLabelFont(CGFloat size) { return LoreSerifFont(size, YES); }
static inline NSFont *LoreLogoFont(CGFloat size) {
    return [NSFont fontWithName:@"Georgia-BoldItalic" size:size] ?: LoreLabelFont(size);
}

// Smoke tests are command-line executables. Give them the same staged resources
// as the app, without an environment-variable override in the shipped product.
inline NSImage *LoreLoadImage(NSString *name) {
#ifdef LORE_TEST_RESOURCE_DIR
    NSString *path = [@LORE_TEST_RESOURCE_DIR stringByAppendingPathComponent:
        [name stringByAppendingPathExtension:@"png"]];
#else
    NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png"];
#endif
    return path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
}

// External inline linkage shares these two caches across the app's view files.
inline NSImage *LoreMascotImage(void) {
    static NSImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ image = LoreLoadImage(@"LoreMascot"); });
    return image;
}

inline NSImage *LorePaperImage(void) {
    static NSImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ image = LoreLoadImage(@"PaperGrain"); });
    return image;
}

static inline void LoreDrawPaper(NSRect rect) {
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast) return;
    NSImage *paper = LorePaperImage();
    if (!paper) return;
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(rect);
    for (CGFloat y = NSMinY(rect); y < NSMaxY(rect); y += 256) {
        for (CGFloat x = NSMinX(rect); x < NSMaxX(rect); x += 256) {
            [paper drawInRect:NSMakeRect(x, y, 256, 256) fromRect:NSZeroRect
                   operation:NSCompositingOperationSourceOver fraction:0.035
              respectFlipped:YES hints:nil];
        }
    }
    [NSGraphicsContext restoreGraphicsState];
}

static inline void LoreDrawHeader(NSRect rect) {
    [LoreColor(LoreHeader) setFill];
    NSRectFill(rect);
    LoreDrawPaper(rect);
    [LoreColor(LoreHeaderText) setStroke];
    for (int index = 1; index <= 2; ++index) {
        CGFloat inset = 4 * index;
        NSBezierPath *rule = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, inset, inset)
                                                           xRadius:12 - inset / 2 yRadius:12 - inset / 2];
        rule.lineWidth = 1;
        [rule stroke];
    }
}

static inline void LoreDrawMedallion(NSRect rect) {
    NSRect circle = NSInsetRect(rect, 1, 1);
    NSBezierPath *path = [NSBezierPath bezierPathWithOvalInRect:circle];
    [LoreColor(LoreGold) setFill];
    [path fill];
    [LoreColor(LoreGoldText) setStroke];
    path.lineWidth = 1.5;
    [path stroke];
    [LoreMascotImage() drawInRect:NSInsetRect(circle, 3, 3) fromRect:NSZeroRect
                       operation:NSCompositingOperationSourceOver fraction:1
                  respectFlipped:YES hints:nil];
}
