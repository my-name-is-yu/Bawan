#pragma once
#import <AppKit/AppKit.h>

void BawanConfigurePaperScrollView(NSScrollView *scroll);

static constexpr CGFloat BawanHeaderHeight = 80;
static constexpr CGFloat BawanBrandMarkSize = 72;
static constexpr CGFloat BawanInputHeight = 28;
static constexpr CGFloat BawanInputFontSize = 13;

typedef NS_ENUM(NSInteger, BawanColorRole) {
    BawanBackground, BawanSurface, BawanText, BawanSecondaryText, BawanBorder,
    BawanButton, BawanHeader, BawanHeaderText, BawanGold, BawanGoldText, BawanSuccess, BawanError, BawanWarning
};

static inline NSColor *BawanRGB(unsigned value) {
    return [NSColor colorWithSRGBRed:((value >> 16) & 255) / 255.0
                              green:((value >> 8) & 255) / 255.0
                               blue:(value & 255) / 255.0 alpha:1];
}

// External inline linkage shares this palette across the app's view files.
inline NSColor *BawanColor(BawanColorRole role) {
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
            NSColor *lightColor = BawanRGB(light[i]);
            NSColor *darkColor = BawanRGB(dark[i]);
            NSColor *contrastLight = (i == BawanBorder || i == BawanSecondaryText) ?
                BawanRGB(0x443024) : lightColor;
            NSColor *contrastDark = (i == BawanBorder || i == BawanSecondaryText) ?
                BawanRGB(0xF5E6C8) : darkColor;
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

static inline NSColor *BawanAccentFillColor(void) { return BawanRGB(0xB53B28); }
static inline NSColor *BawanAccentColor(void) { return BawanColor(BawanError); }

// A pressed primary action darkens in both appearances; its ivory label keeps
// at least 4.5:1 contrast instead of blending the red toward light text in dark mode.
static inline NSColor *BawanPrimaryButtonFill(BOOL highlighted) {
    return highlighted ? BawanRGB(0x943020) : BawanAccentFillColor();
}

static inline NSImage *BawanSymbol(NSString *name, NSString *description, CGFloat size) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:description];
    return [image imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightMedium]];
}

static inline NSBezierPath *BawanCutCornerPath(NSRect rect) {
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

static inline NSBezierPath *BawanInputPath(NSRect rect) {
    return [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 1, 1) xRadius:6 yRadius:6];
}

static inline void BawanDrawInputSurface(NSRect rect, BOOL enabled, BOOL highlighted) {
    NSBezierPath *path = BawanInputPath(rect);
    NSColor *fill = BawanColor(enabled && highlighted ? BawanButton : BawanBackground);
    [(enabled ? fill : [fill colorWithAlphaComponent:0.4]) setFill];
    [path fill];
    [BawanColor(BawanBorder) setStroke];
    path.lineWidth = 1.5;
    [path stroke];
}

static inline NSFont *BawanSerifFont(CGFloat size, BOOL bold) {
    NSFont *latin = [NSFont fontWithName:bold ? @"Georgia-Bold" : @"Georgia" size:size];
    if (!latin) latin = [NSFont systemFontOfSize:size weight:bold ? NSFontWeightSemibold : NSFontWeightRegular];
    NSFontDescriptor *japanese = [NSFontDescriptor fontDescriptorWithName:
        bold ? @"HiraMinProN-W6" : @"HiraMinProN-W3" size:size];
    NSFontDescriptor *descriptor = [latin.fontDescriptor fontDescriptorByAddingAttributes:
        @{NSFontCascadeListAttribute: @[japanese]}];
    return [NSFont fontWithDescriptor:descriptor size:size] ?: latin;
}

static inline NSFont *BawanBodyFont(CGFloat size) { return BawanSerifFont(size, NO); }
static inline NSFont *BawanLabelFont(CGFloat size) { return BawanSerifFont(size, YES); }

// Smoke tests are command-line executables. Give them the same staged resources
// as the app, without an environment-variable override in the shipped product.
inline NSImage *BawanLoadImage(NSString *name) {
#ifdef BAWAN_TEST_RESOURCE_DIR
    NSString *path = [@BAWAN_TEST_RESOURCE_DIR stringByAppendingPathComponent:
        [name stringByAppendingPathExtension:@"png"]];
#else
    NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png"];
#endif
    return path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
}

// External inline linkage shares these two caches across the app's view files.
NSImage *BawanMascotImage(void);

inline NSImage *BawanPaperImage(void) {
    static NSImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ image = BawanLoadImage(@"PaperGrain"); });
    return image;
}

static inline void BawanDrawPaper(NSRect rect) {
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast) return;
    NSImage *paper = BawanPaperImage();
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

static inline void BawanDrawHeader(NSRect rect) {
    [BawanColor(BawanHeader) setFill];
    NSRectFill(rect);
    BawanDrawPaper(rect);
    [BawanColor(BawanHeaderText) setStroke];
    for (int index = 1; index <= 2; ++index) {
        CGFloat inset = 4 * index;
        NSBezierPath *rule = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, inset, inset)
                                                           xRadius:12 - inset / 2 yRadius:12 - inset / 2];
        rule.lineWidth = 1;
        [rule stroke];
    }
}

static inline void BawanDrawMedallionBase(NSRect rect) {
    NSRect circle = NSInsetRect(rect, 1, 1);
    NSBezierPath *path = [NSBezierPath bezierPathWithOvalInRect:circle];
    [BawanColor(BawanGold) setFill];
    [path fill];
    [BawanColor(BawanGoldText) setStroke];
    path.lineWidth = 1.5;
    [path stroke];
}

