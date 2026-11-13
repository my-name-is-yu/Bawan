#import "LoreAppearance.h"

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
