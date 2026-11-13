#import "LoreAppearance.h"
#import <ImageIO/ImageIO.h>

NSImage *LoreMascotImage(void) {
    static NSImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
#ifdef LORE_TEST_RESOURCE_DIR
        NSString *path = [@LORE_TEST_RESOURCE_DIR stringByAppendingPathComponent:@"LoreMascot.png"];
#else
        NSString *path = [NSBundle.mainBundle pathForResource:@"LoreMascot" ofType:@"png"];
#endif
        if (!path) return;
        // Decode only the display-size thumbnail; never retain the 1254px original.
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
            (__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCache:@NO});
        if (!source) return;
        CGImageRef bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{
            (id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
            (id)kCGImageSourceCreateThumbnailWithTransform:@YES,
            (id)kCGImageSourceThumbnailMaxPixelSize:@144,
            (id)kCGImageSourceShouldCacheImmediately:@YES
        });
        CFRelease(source);
        if (!bitmap) return;
        image = [[NSImage alloc] initWithCGImage:bitmap size:NSMakeSize(72, 72)];
        CGImageRelease(bitmap);
    });
    return image;
}

@interface LorePaperClipView : NSClipView
@end

@implementation LorePaperClipView
- (BOOL)isOpaque { return YES; }
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.backgroundColor = LoreColor(LoreBackground);
    self.enclosingScrollView.backgroundColor = LoreColor(LoreBackground);
    self.enclosingScrollView.needsDisplay = YES;
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    [LoreColor(LoreBackground) setFill];
    NSRectFill(dirtyRect);
    LoreDrawPaper(self.bounds);
}
@end

@interface LorePaperScroller : NSScroller
@end

@implementation LorePaperScroller
+ (BOOL)isCompatibleWithOverlayScrollers { return self == LorePaperScroller.class; }
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)drawKnobSlotInRect:(NSRect)slotRect highlight:(BOOL)highlight {
    if (self.scrollerStyle == NSScrollerStyleOverlay) {
        [super drawKnobSlotInRect:slotRect highlight:highlight];
    } else {
        // Paint the full legacy gutter; AppKit still draws and tracks its knob.
        [LoreColor(LoreBackground) setFill];
        NSRectFill(self.bounds);
    }
}
@end

void LoreConfigurePaperScrollView(NSScrollView *scroll) {
    scroll.hasVerticalScroller = YES;
    scroll.verticalScroller = [[LorePaperScroller alloc] initWithFrame:NSMakeRect(0, 0, 16, 100)];
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    scroll.drawsBackground = YES;
    scroll.backgroundColor = LoreColor(LoreBackground);
    scroll.contentView = [[LorePaperClipView alloc] initWithFrame:scroll.contentView.frame];
    scroll.contentView.drawsBackground = YES;
    scroll.contentView.backgroundColor = LoreColor(LoreBackground);
}
