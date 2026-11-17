#import "SetupUI.h"
#import "BawanChrome.h"

@implementation BawanSetupKeycap
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.editable = NO;
        self.selectable = NO;
        self.bordered = NO;
        self.drawsBackground = NO;
        self.font = BawanLabelFont(BawanInputFontSize);
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
        self.borderWidth = BawanChromeLineWidth;
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

@interface BawanSetupRuleView : NSView
@end

@implementation BawanSetupRuleView
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    [BawanColor(BawanBorder) setFill];
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
    button.font = BawanLabelFont(13);
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
