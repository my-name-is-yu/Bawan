#pragma once
#import <AppKit/AppKit.h>

void LoreConfigurePaperScrollView(NSScrollView *scroll);

static constexpr CGFloat LoreHeaderHeight = 80;
static constexpr CGFloat LoreBrandMarkSize = 64;
static constexpr CGFloat LoreBrandLogoSize = 48;
static constexpr CGFloat LoreBrandLeading = 80;
static constexpr CGFloat LoreBrandGap = 12;
static constexpr CGFloat LoreInputHeight = 28;
static constexpr CGFloat LoreInputFontSize = 13;

typedef NS_ENUM(NSInteger, LoreColorRole) {
    LoreBackground, LoreSurface, LoreText, LoreSecondaryText, LoreBorder,
    LoreButton, LoreHeader, LoreHeaderText, LoreGold, LoreGoldText, LoreSuccess, LoreError, LoreWarning
};

static inline NSColor *LoreRGB(unsigned value) {
    return [NSColor colorWithSRGBRed:((value >> 16) & 255) / 255.0
                              green:((value >> 8) & 255) / 255.0
                               blue:(value & 255) / 255.0 alpha:1];
}

// External inline linkage shares this palette across the app's view files.
inline NSColor *LoreColor(LoreColorRole role) {
    static NSArray<NSColor *> *palette;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const unsigned light[] = {
            0xF7E7BB, 0xFFF1CE, 0x443024, 0x72543B, 0x624530, 0xF2DBA8,
            0xB53B28, 0xF7E7BB, 0xD99E3D, 0x443024, 0x35603B, 0xB53B28, 0x76520D
        };
        const unsigned dark[] = {
            0x28211C, 0x332821, 0xF5E6C8, 0xC9B594, 0xA88150, 0x493725,
            0x7B2D20, 0xF5E6C8, 0xC99B53, 0x28211C, 0x9BC29A, 0xF08A63, 0xE3B76A
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

// A pressed primary action darkens in both appearances; its ivory label keeps
// at least 4.5:1 contrast instead of blending the red toward light text in dark mode.
static inline NSColor *LorePrimaryButtonFill(BOOL highlighted) {
    return highlighted ? LoreRGB(0x943020) : LoreAccentFillColor();
}

static inline NSImage *LoreSymbol(NSString *name, NSString *description, CGFloat size) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:description];
    return [image imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightMedium]];
}

static inline NSBezierPath *LoreCutCornerPath(NSRect rect) {
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:NSMakePoint(NSMinX(rect) + 5, NSMinY(rect))];
    [path lineToPoint:NSMakePoint(NSMaxX(rect) - 5, NSMinY(rect))];
    [path lineToPoint:NSMakePoint(NSMaxX(rect), NSMinY(rect) + 5)];
    [path lineToPoint:NSMakePoint(NSMaxX(rect), NSMaxY(rect) - 5)];
    [path lineToPoint:NSMakePoint(NSMaxX(rect) - 5, NSMaxY(rect))];
    [path lineToPoint:NSMakePoint(NSMinX(rect) + 5, NSMaxY(rect))];
    [path lineToPoint:NSMakePoint(NSMinX(rect), NSMaxY(rect) - 5)];
    [path lineToPoint:NSMakePoint(NSMinX(rect), NSMinY(rect) + 5)];
    [path closePath];
    return path;
}

static inline NSBezierPath *LoreInputPath(NSRect rect) {
    return [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 1, 1) xRadius:6 yRadius:6];
}

static inline void LoreDrawInputSurface(NSRect rect, BOOL enabled, BOOL highlighted) {
    NSBezierPath *path = LoreInputPath(rect);
    NSColor *fill = LoreColor(enabled && highlighted ? LoreButton : LoreBackground);
    [(enabled ? fill : [fill colorWithAlphaComponent:0.4]) setFill];
    [path fill];
    [LoreColor(LoreBorder) setStroke];
    path.lineWidth = 1.5;
    [path stroke];
}

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
