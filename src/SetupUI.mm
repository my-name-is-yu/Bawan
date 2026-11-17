#import "SetupUI.h"
#import "BawanChrome.h"

#include <algorithm>
#include <cmath>

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

static constexpr CGFloat BawanCheckboxSize = 18;
static constexpr CGFloat BawanCheckboxGap = 8;

@implementation BawanCheckbox
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setButtonType:NSButtonTypeSwitch];
        self.bordered = NO;
        self.font = BawanLabelFont(BawanSetupRowTitleSize);
        self.focusRingType = NSFocusRingTypeExterior;
        self.translatesAutoresizingMaskIntoConstraints = NO;
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (NSRect)boxRect {
    return NSMakeRect(0, floor((NSHeight(self.bounds) - BawanCheckboxSize) / 2), BawanCheckboxSize, BawanCheckboxSize);
}
- (NSSize)intrinsicContentSize {
    NSSize title = [self.title sizeWithAttributes:@{NSFontAttributeName:self.font}];
    return NSMakeSize(BawanCheckboxSize + BawanCheckboxGap + ceil(title.width), std::max(BawanCheckboxSize, ceil(title.height)));
}
- (void)setTitle:(NSString *)title {
    [super setTitle:title];
    [self invalidateIntrinsicContentSize];
}
- (NSRect)focusRingMaskBounds { return [self boxRect]; }
- (NSBezierPath *)bawanFocusRingPath { return BawanInputPath([self boxRect]); }
- (void)drawRect:(NSRect)dirtyRect {
    NSRect box = [self boxRect];
    BOOL on = self.state == NSControlStateValueOn;
    BOOL highlighted = self.cell.highlighted;
    if (on) {
        NSBezierPath *path = BawanInputPath(box);
        BawanDrawControlSurface(path, BawanPrimaryButtonFill(highlighted), self.enabled);
        NSBezierPath *check = [NSBezierPath bezierPath];
        [check moveToPoint:NSMakePoint(NSMinX(box) + 4.5, NSMidY(box))];
        [check lineToPoint:NSMakePoint(NSMinX(box) + 7.5, NSMaxY(box) - 5)];
        [check lineToPoint:NSMakePoint(NSMaxX(box) - 4, NSMinY(box) + 5)];
        check.lineWidth = 2;
        check.lineCapStyle = NSLineCapStyleRound;
        check.lineJoinStyle = NSLineJoinStyleRound;
        [BawanAccentForegroundColor() setStroke];
        [check stroke];
    } else {
        BawanDrawInputSurface(box, self.enabled, highlighted);
    }
    NSColor *color = BawanColor(BawanText);
    if (!self.enabled) color = [BawanColor(BawanSecondaryText) colorWithAlphaComponent:BawanDisabledAlpha];
    NSDictionary *attributes = @{NSFontAttributeName:self.font, NSForegroundColorAttributeName:color};
    NSSize size = [self.title sizeWithAttributes:attributes];
    [self.title drawAtPoint:NSMakePoint(NSMaxX(box) + BawanCheckboxGap, floor((NSHeight(self.bounds) - size.height) / 2))
             withAttributes:attributes];
}
@end

@implementation BawanToggle
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setButtonType:NSButtonTypePushOnPushOff];
        self.bordered = NO;
        self.title = @"";
        self.focusRingType = NSFocusRingTypeExterior;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self setAccessibilityRole:NSAccessibilityCheckBoxRole];
        [self setAccessibilitySubrole:NSAccessibilitySwitchSubrole];
    }
    return self;
}
- (NSSize)intrinsicContentSize { return NSMakeSize(42, 24); }
- (NSBezierPath *)trackPath {
    NSRect track = NSInsetRect(self.bounds, 1, 1);
    return [NSBezierPath bezierPathWithRoundedRect:track xRadius:NSHeight(track) / 2 yRadius:NSHeight(track) / 2];
}
- (NSRect)focusRingMaskBounds { return self.bounds; }
- (NSBezierPath *)bawanFocusRingPath { return [self trackPath]; }
- (id)accessibilityValue { return @(self.state == NSControlStateValueOn); }
- (void)drawRect:(NSRect)dirtyRect {
    BOOL on = self.state == NSControlStateValueOn;
    NSBezierPath *track = [self trackPath];
    NSColor *fill = on ? BawanPrimaryButtonFill(self.cell.highlighted) :
        BawanColor(self.cell.highlighted ? BawanButton : BawanBackground);
    BawanDrawControlSurface(track, fill, self.enabled);
    CGFloat diameter = NSHeight(self.bounds) - 8;
    CGFloat x = on ? NSMaxX(self.bounds) - 4 - diameter : 4;
    NSBezierPath *knob = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(x, floor((NSHeight(self.bounds) - diameter) / 2), diameter, diameter)];
    [(on ? BawanAccentForegroundColor() : BawanColor(BawanBorder)) setFill];
    [knob fill];
}
@end

@implementation BawanProgressBar {
    NSTimer *_animation;
    CGFloat _phase;
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)startAnimation:(id)sender {
    if (_animation || !self.indeterminate) return;
    __weak BawanProgressBar *weakSelf = self;
    _animation = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 repeats:YES block:^(__unused NSTimer *timer) {
        BawanProgressBar *bar = weakSelf;
        if (!bar) return;
        bar->_phase = std::fmod(bar->_phase + 0.02, 1.3);
        bar.needsDisplay = YES;
    }];
}
- (void)stopAnimation:(id)sender {
    [_animation invalidate];
    _animation = nil;
    _phase = 0;
    self.needsDisplay = YES;
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) [self stopAnimation:nil];
}
- (void)setDoubleValue:(double)value {
    [super setDoubleValue:value];
    self.needsDisplay = YES;
}
- (void)setIndeterminate:(BOOL)indeterminate {
    [super setIndeterminate:indeterminate];
    if (!indeterminate) [self stopAnimation:nil];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect track = NSInsetRect(self.bounds, BawanChromeLineWidth / 2, BawanChromeLineWidth / 2);
    CGFloat radius = NSHeight(track) / 2;
    NSBezierPath *trackPath = [NSBezierPath bezierPathWithRoundedRect:track xRadius:radius yRadius:radius];
    [BawanColor(BawanBackground) setFill];
    [trackPath fill];
    NSRect fill = track;
    if (self.indeterminate) {
        // A segment sweeps across the track while the length is unknown.
        CGFloat width = NSWidth(track) * 0.3;
        fill.origin.x = NSMinX(track) + (_phase - 0.3) * NSWidth(track);
        fill.size.width = width;
    } else {
        double span = self.maxValue - self.minValue;
        double fraction = span > 0 ? std::clamp((self.doubleValue - self.minValue) / span, 0.0, 1.0) : 0;
        fill.size.width = NSWidth(track) * fraction;
    }
    [NSGraphicsContext saveGraphicsState];
    [trackPath addClip];
    [BawanPrimaryButtonFill(NO) setFill];
    NSRectFill(fill);
    [NSGraphicsContext restoreGraphicsState];
    [BawanColor(BawanBorder) setStroke];
    trackPath.lineWidth = BawanChromeLineWidth;
    [trackPath stroke];
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

void BawanSetupPresentPage(NSView *page, NSScrollView *scroll) {
    [scroll.documentView scrollPoint:NSZeroPoint];
    [scroll reflectScrolledClipView:scroll.contentView];
    if ([page isKindOfClass:BawanSurfaceView.class]) ((BawanSurfaceView *)page).acceptsKeyFocus = YES;
    [page.window recalculateKeyViewLoop];
    [page.window makeFirstResponder:page];
}

NSTextField *BawanSetupHeading(NSString *text, CGFloat size) {
    return BawanLabelWithFont(text, BawanLabelFont(size), BawanColor(BawanText));
}

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

NSView *BawanSetupRule(void) {
    NSView *rule = [[BawanSetupRuleView alloc] initWithFrame:NSZeroRect];
    rule.translatesAutoresizingMaskIntoConstraints = NO;
    [rule.heightAnchor constraintEqualToConstant:1].active = YES;
    return rule;
}

BawanActionButton *BawanSetupButton(NSString *identifier, NSString *title, CGFloat width, id target, SEL action) {
    BawanActionButton *button = BawanAddActionButton(nil, identifier, title, target, action, NO);
    button.font = BawanLabelFont(BawanSetupCaptionSize);
    [button.widthAnchor constraintEqualToConstant:width].active = YES;
    [button.heightAnchor constraintEqualToConstant:BawanSetupButtonHeight].active = YES;
    return button;
}

NSView *BawanSetupRow(NSString *identifier, NSView *title, NSView *status, NSArray<NSView *> *controls) {
    return BawanSetupInsetRow(identifier, title, status, controls, 0, 0);
}

NSView *BawanSetupInsetRow(NSString *identifier, NSView *title, NSView *status, NSArray<NSView *> *controls,
                           CGFloat leadingInset, CGFloat trailingInset) {
    NSView *row = [[NSView alloc] init];
    row.identifier = identifier;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *description = BawanSetupStack(@[title, status], NSUserInterfaceLayoutOrientationVertical, 4);
    // A hidden action keeps its slot so the key columns line up from row to row.
    // Set this before adding views; a stack detaches hidden views as they arrive.
    NSStackView *trailing = BawanSetupStack(@[], NSUserInterfaceLayoutOrientationHorizontal, 8);
    trailing.detachesHiddenViews = NO;
    for (NSView *control in controls) [trailing addArrangedSubview:control];
    [row addSubview:description];
    [row addSubview:trailing];
    [description setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];
    // Rows sit at their minimum height and grow only when a wrapped status needs it.
    NSLayoutConstraint *compact = [row.heightAnchor constraintEqualToConstant:BawanSetupRowHeight];
    compact.priority = NSLayoutPriorityDefaultLow;
    compact.active = YES;
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:BawanSetupRowHeight],
        [description.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:leadingInset],
        [description.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [description.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:6],
        [description.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor constant:-6],
        [description.trailingAnchor constraintLessThanOrEqualToAnchor:trailing.leadingAnchor constant:-12],
        [trailing.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-trailingInset],
        [trailing.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [trailing.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:6],
        [trailing.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor constant:-6]
    ]];
    return row;
}
