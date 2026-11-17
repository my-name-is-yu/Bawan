#import "SetupUI.h"

@implementation BawanSetupPaper
- (void)setMasthead:(BOOL)masthead {
    _masthead = masthead;
    self.needsDisplay = YES;
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    if (_masthead) {
        BawanDrawHeader(self.bounds);
    } else {
        [BawanColor(BawanBackground) setFill];
        NSRectFill(self.bounds);
        BawanDrawPaper(self.bounds);
    }
}
@end

@implementation BawanSetupKeycap
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.editable = NO;
        self.selectable = NO;
        self.bordered = NO;
        self.drawsBackground = NO;
        self.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
        self.textColor = BawanColor(BawanText);
    }
    return self;
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    BawanDrawInputSurface(self.bounds, YES, NO);
    NSDictionary *attributes = @{NSFontAttributeName:self.font,
        NSForegroundColorAttributeName:self.textColor};
    NSSize size = [self.stringValue sizeWithAttributes:attributes];
    [self.stringValue drawAtPoint:NSMakePoint(floor((NSWidth(self.bounds) - size.width) / 2),
        floor((NSHeight(self.bounds) - size.height) / 2)) withAttributes:attributes];
}
@end

@implementation BawanSetupDocument
- (BOOL)isFlipped { return YES; }
@end

@implementation BawanSetupGroup
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.boxType = NSBoxCustom;
        self.titlePosition = NSNoTitle;
        self.borderWidth = 1;
        self.borderColor = BawanColor(BawanBorder);
        self.fillColor = BawanColor(BawanSurface);
        self.cornerRadius = 8;
        self.contentViewMargins = NSZeroSize;
    }
    return self;
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.borderColor = BawanColor(BawanBorder);
    self.fillColor = BawanColor(BawanSurface);
    self.needsDisplay = YES;
}
@end

@implementation BawanSetupActionButton
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.bordered = NO;
        self.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        self.focusRingType = NSFocusRingTypeExterior;
    }
    return self;
}
- (void)setPrimary:(BOOL)primary {
    _primary = primary;
    [self invalidateIntrinsicContentSize];
    self.needsDisplay = YES;
}
- (NSSize)intrinsicContentSize {
    NSSize text = [self.title sizeWithAttributes:@{NSFontAttributeName:self.font}];
    return NSMakeSize(ceil(text.width) + 32, _primary ? 40 : 30);
}
- (NSRect)alignmentRectForFrame:(NSRect)frame { return frame; }
- (NSRect)frameForAlignmentRect:(NSRect)rect { return rect; }
- (NSRect)focusRingMaskBounds { return BawanInputPath(self.bounds).bounds; }
- (void)drawFocusRingMask { [BawanInputPath(self.bounds) fill]; }
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    if (_primary && self.enabled) {
        [BawanPrimaryButtonFill(self.cell.highlighted) setFill];
        [BawanInputPath(self.bounds) fill];
    } else {
        BawanDrawInputSurface(self.bounds, self.enabled, self.cell.highlighted);
    }
    NSColor *color = _primary && self.enabled ? BawanRGB(0xF7E7BB) : BawanColor(BawanText);
    if (!self.enabled) color = [BawanColor(BawanSecondaryText) colorWithAlphaComponent:0.65];
    NSDictionary *attributes = @{NSFontAttributeName:self.font, NSForegroundColorAttributeName:color};
    NSSize size = [self.title sizeWithAttributes:attributes];
    [self.title drawAtPoint:NSMakePoint(floor((NSWidth(self.bounds) - size.width) / 2),
        floor((NSHeight(self.bounds) - size.height) / 2)) withAttributes:attributes];
}
@end

@interface BawanSetupRuleView : NSView
@end

@implementation BawanSetupRuleView
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    [[BawanColor(BawanBorder) colorWithAlphaComponent:0.45] setFill];
    NSRectFill(self.bounds);
}
@end

NSStackView *BawanSetupStack(NSArray<NSView *> *views, NSUserInterfaceLayoutOrientation orientation, CGFloat spacing) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = orientation;
    stack.alignment = orientation == NSUserInterfaceLayoutOrientationVertical ?
        NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    stack.spacing = spacing;
    stack.detachesHiddenViews = YES;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    return stack;
}

NSButton *BawanSetupLink(NSString *title, id target, SEL action) {
    NSButton *button = [NSButton buttonWithTitle:title target:target action:action];
    button.bordered = NO;
    button.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
    button.contentTintColor = BawanAccentColor();
    button.translatesAutoresizingMaskIntoConstraints = NO;
    return button;
}

NSView *BawanSetupRule(void) {
    NSView *rule = [[BawanSetupRuleView alloc] initWithFrame:NSZeroRect];
    rule.translatesAutoresizingMaskIntoConstraints = NO;
    [rule.heightAnchor constraintEqualToConstant:1].active = YES;
    return rule;
}
