#import "SetupUI.h"
#import "BawanChrome.h"
#import <QuartzCore/QuartzCore.h>

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
    if (!self.enabled) color = [color colorWithAlphaComponent:BawanDisabledAlpha];
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

static char ProgressWindowVisibilityContext;

@implementation BawanProgressBar {
    CALayer *_marqueeClip;
    CALayer *_marquee;
    CAShapeLayer *_marqueeBorder;
    BOOL _animationRequested;
    BOOL _windowClosing;
    __weak NSWindow *_observedWindow;
}
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        _marqueeClip = [CALayer layer];
        _marqueeClip.masksToBounds = YES;
        _marquee = [CALayer layer];
        [_marqueeClip addSublayer:_marquee];
        _marqueeBorder = [CAShapeLayer layer];
        _marqueeBorder.fillColor = nil;
        [self.layer addSublayer:_marqueeClip];
        [self.layer addSublayer:_marqueeBorder];
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
            selector:@selector(accessibilityChanged:)
            name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
        [self updateMarquee];
    }
    return self;
}
- (void)updateMarquee {
    if (!_marquee) return;
    NSRect track = NSInsetRect(self.bounds, BawanChromeLineWidth / 2, BawanChromeLineWidth / 2);
    track.size.width = std::max(CGFloat(0), NSWidth(track));
    track.size.height = std::max(CGFloat(0), NSHeight(track));
    const CGFloat radius = std::min(NSWidth(track), NSHeight(track)) / 2;
    const BOOL hasTrack = NSWidth(track) > 0 && NSHeight(track) > 0;
    BOOL resized = !CGSizeEqualToSize(_marqueeClip.bounds.size, track.size);
    NSWindow *window = self.window;
    BOOL animate = _animationRequested && self.indeterminate && !self.hiddenOrHasHiddenAncestor &&
        window.visible && (window.occlusionState & NSWindowOcclusionStateVisible) &&
        !_windowClosing && hasTrack &&
        !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _marqueeClip.hidden = _marqueeBorder.hidden = !self.indeterminate;
    _marqueeClip.frame = track;
    _marqueeClip.cornerRadius = radius;
    _marquee.bounds = CGRectMake(0, 0, NSWidth(track) * 0.3, NSHeight(track));
    // The model layer remains a visible, stationary unknown-length indicator.
    _marquee.position = CGPointMake(NSWidth(track) / 2, NSHeight(track) / 2);
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self->_marquee.backgroundColor = BawanPrimaryButtonFill(NO).CGColor;
        self->_marqueeBorder.strokeColor = BawanColor(BawanBorder).CGColor;
    }];
    _marqueeBorder.frame = self.bounds;
    CGPathRef border = self.indeterminate && hasTrack ?
        CGPathCreateWithRoundedRect(NSRectToCGRect(track), radius, radius, nullptr) : nullptr;
    _marqueeBorder.path = border;
    CGPathRelease(border);
    _marqueeBorder.contentsScale = window.backingScaleFactor ?: 1;
    _marqueeBorder.lineWidth = BawanChromeLineWidth;
    if (!animate || resized) [_marquee removeAnimationForKey:@"bawan.marquee"];
    if (animate && ![_marquee animationForKey:@"bawan.marquee"]) {
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"position.x"];
        animation.fromValue = @(-NSWidth(track) * 0.15);
        animation.toValue = @(NSWidth(track) * 1.15);
        animation.duration = 65.0 / 30.0;
        animation.repeatCount = HUGE_VALF;
        animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [_marquee addAnimation:animation forKey:@"bawan.marquee"];
    }
    [CATransaction commit];
}
- (void)layout {
    [super layout];
    [self updateMarquee];
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateMarquee];
    self.needsDisplay = YES;
}
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self updateMarquee];
}
- (void)startAnimation:(id)sender {
    _animationRequested = YES;
    [self updateMarquee];
}
- (void)stopAnimation:(id)sender {
    _animationRequested = NO;
    [self updateMarquee];
}
- (void)viewDidHide { [super viewDidHide]; [self updateMarquee]; }
- (void)viewDidUnhide { [super viewDidUnhide]; [self updateMarquee]; }
- (void)viewWillMoveToWindow:(NSWindow *)window {
    [self stopObservingWindow];
    [_marquee removeAnimationForKey:@"bawan.marquee"];
    _windowClosing = NO;
    [super viewWillMoveToWindow:window];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    NSWindow *window = self.window;
    if (window) {
        _observedWindow = window;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowWillClose:)
            name:NSWindowWillCloseNotification object:window];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowVisibilityChanged:)
            name:NSWindowDidChangeOcclusionStateNotification object:window];
        // Ordering can change visible while the occlusion state stays the same.
        [window addObserver:self forKeyPath:@"visible" options:0 context:&ProgressWindowVisibilityContext];
    }
    [self updateMarquee];
}
- (void)stopObservingWindow {
    NSWindow *window = _observedWindow;
    if (!window) return;
    [NSNotificationCenter.defaultCenter removeObserver:self name:nil object:window];
    [window removeObserver:self forKeyPath:@"visible" context:&ProgressWindowVisibilityContext];
    _observedWindow = nil;
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (context == &ProgressWindowVisibilityContext) {
        [self windowVisibilityChanged:nil];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}
- (void)windowWillClose:(NSNotification *)notification {
    _windowClosing = YES;
    [self updateMarquee];
}
- (void)windowVisibilityChanged:(NSNotification *)notification {
    if (self.window.visible) _windowClosing = NO;
    [self updateMarquee];
}
- (void)accessibilityChanged:(NSNotification *)notification { [self updateMarquee]; }
- (void)setDoubleValue:(double)value {
    [super setDoubleValue:value];
    self.needsDisplay = YES;
}
- (void)setIndeterminate:(BOOL)indeterminate {
    // AppKit calls stopAnimation: from this setter; retain the caller's intent.
    BOOL requested = _animationRequested;
    [super setIndeterminate:indeterminate];
    _animationRequested = requested;
    [self updateMarquee];
    self.needsDisplay = YES;
}
- (void)dealloc {
    [self stopObservingWindow];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect track = NSInsetRect(self.bounds, BawanChromeLineWidth / 2, BawanChromeLineWidth / 2);
    if (NSIsEmptyRect(track)) return;
    CGFloat radius = std::min(NSWidth(track), NSHeight(track)) / 2;
    NSBezierPath *trackPath = [NSBezierPath bezierPathWithRoundedRect:track xRadius:radius yRadius:radius];
    [BawanColor(BawanBackground) setFill];
    [trackPath fill];
    NSRect fill = track;
    if (!self.indeterminate) {
        double span = self.maxValue - self.minValue;
        double fraction = span > 0 ? std::clamp((self.doubleValue - self.minValue) / span, 0.0, 1.0) : 0;
        fill.size.width = NSWidth(track) * fraction;
        [NSGraphicsContext saveGraphicsState];
        [trackPath addClip];
        [BawanPrimaryButtonFill(NO) setFill];
        NSRectFill(fill);
        [NSGraphicsContext restoreGraphicsState];
    }
    if (!self.indeterminate) {
        [BawanColor(BawanBorder) setStroke];
        trackPath.lineWidth = BawanChromeLineWidth;
        [trackPath stroke];
    }
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
