#import "BawanAppearance.h"
#import <ImageIO/ImageIO.h>

NSImage *BawanMascotImage(void) {
    static NSImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
#ifdef BAWAN_TEST_RESOURCE_DIR
        NSString *path = [@BAWAN_TEST_RESOURCE_DIR stringByAppendingPathComponent:@"BawanMascot.png"];
#else
        NSString *path = [NSBundle.mainBundle pathForResource:@"BawanMascot" ofType:@"png"];
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

@interface BawanPaperClipView : NSClipView
@end

@implementation BawanPaperClipView
- (BOOL)isOpaque { return YES; }
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.backgroundColor = BawanColor(BawanBackground);
    self.enclosingScrollView.backgroundColor = BawanColor(BawanBackground);
    self.enclosingScrollView.needsDisplay = YES;
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    [BawanColor(BawanBackground) setFill];
    NSRectFill(dirtyRect);
    BawanDrawPaper(self.bounds);
}
@end

@interface BawanPaperScroller : NSScroller
@end

@implementation BawanPaperScroller
+ (BOOL)isCompatibleWithOverlayScrollers { return self == BawanPaperScroller.class; }
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)drawKnobSlotInRect:(NSRect)slotRect highlight:(BOOL)highlight {
    if (self.scrollerStyle == NSScrollerStyleOverlay) {
        [super drawKnobSlotInRect:slotRect highlight:highlight];
    } else {
        // Paint the full legacy gutter; AppKit still draws and tracks its knob.
        [BawanColor(BawanBackground) setFill];
        NSRectFill(self.bounds);
    }
}
@end

void BawanConfigurePaperScrollView(NSScrollView *scroll) {
    scroll.hasVerticalScroller = YES;
    scroll.verticalScroller = [[BawanPaperScroller alloc] initWithFrame:NSMakeRect(0, 0, 16, 100)];
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    scroll.drawsBackground = YES;
    scroll.backgroundColor = BawanColor(BawanBackground);
    scroll.contentView = [[BawanPaperClipView alloc] initWithFrame:scroll.contentView.frame];
    scroll.contentView.drawsBackground = YES;
    scroll.contentView.backgroundColor = BawanColor(BawanBackground);
}
