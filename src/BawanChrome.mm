#import "BawanChrome.h"
#import "BawanMascotView.h"
#import <QuartzCore/CALayer.h>
#import <QuartzCore/CAAnimation.h>
#import <QuartzCore/CAMediaTimingFunction.h>
#import <QuartzCore/CATransaction.h>

namespace {
void DrawButton(NSRect frame, BOOL primary, BOOL gold, BOOL highlighted, BOOL enabled) {
    NSColor *fill = primary ? BawanPrimaryButtonFill(highlighted) : BawanColor(gold ? BawanGold : BawanBackground);
    if (enabled && highlighted && !primary) fill = [fill blendedColorWithFraction:0.12 ofColor:BawanColor(BawanText)];
    NSRect face = NSInsetRect(frame, 1, 1);
    face.size.height -= 3;
    NSBezierPath *path = gold ? BawanCutCornerPath(face) :
        [NSBezierPath bezierPathWithRoundedRect:face xRadius:8 yRadius:8];
    if (enabled) {
        NSBezierPath *shadow = [path copy];
        NSAffineTransform *offset = [NSAffineTransform transform];
        [offset translateXBy:0 yBy:3];
        [shadow transformUsingAffineTransform:offset];
        [BawanColor(BawanBorder) setFill];
        [shadow fill];
    }
    BawanDrawControlSurface(path, fill, enabled);
}
}

@implementation BawanBorderlessButton
BAWAN_BORDERLESS_CONTROL_METHODS([self bawanFocusRingPath])
- (NSBezierPath *)bawanFocusRingPath { return nil; }
@end

@implementation BawanSurfaceView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return self.acceptsKeyFocus; }
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    if (self.masthead) { BawanDrawHeader(self.bounds); return; }
    NSRect frame = self.borderColor ? NSInsetRect(self.bounds, BawanChromeLineWidth / 2, BawanChromeLineWidth / 2) : self.bounds;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:frame xRadius:self.cornerRadius yRadius:self.cornerRadius];
    [self.fillColor setFill];
    [path fill];
    if (self.textured) {
        [NSGraphicsContext saveGraphicsState];
        [path addClip];
        BawanDrawPaper(self.bounds);
        [NSGraphicsContext restoreGraphicsState];
    }
    if (self.borderColor) {
        [self.borderColor setStroke];
        path.lineWidth = BawanChromeLineWidth;
        [path stroke];
    }
}
@end

@implementation BawanActionButton {
    BOOL _trackingPointer;
}
- (void)resetPressFeedback {
    _trackingPointer = NO;
    [self.layer removeAnimationForKey:@"bawan.press"];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.transform = CATransform3DIdentity;
    [CATransaction commit];
}
- (void)animatePressed:(BOOL)pressed {
    CALayer *layer = self.layer;
    if (!layer || !self.window.visible || NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        [self resetPressFeedback];
        return;
    }
    CALayer *presentation = layer.presentationLayer;
    CATransform3D current = presentation ? presentation.transform : layer.transform;
    CGFloat scale = pressed ? 0.98 : 1;
    CATransform3D target = CATransform3DMakeScale(scale, scale, 1);
    // AppKit owns anchorPoint/position. Compensate inside the transform so the
    // control scales around its center without changing hit testing or layout.
    target.m41 = (0.5 - layer.anchorPoint.x) * NSWidth(self.bounds) * (1 - scale);
    target.m42 = (0.5 - layer.anchorPoint.y) * NSHeight(self.bounds) * (1 - scale);
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"transform"];
    animation.fromValue = [NSValue valueWithCATransform3D:current];
    animation.toValue = [NSValue valueWithCATransform3D:target];
    animation.duration = 0.12;
    animation.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.23 :1 :0.32 :1];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.transform = target;
    [layer addAnimation:animation forKey:@"bawan.press"];
    [CATransaction commit];
}
- (void)mouseDown:(NSEvent *)event {
    if (!self.pressFeedback || !self.enabled) {
        [super mouseDown:event];
        return;
    }
    _trackingPointer = YES;
    [self animatePressed:YES];
    @try {
        [super mouseDown:event];
    } @finally {
        // Dragging outside the button does not send an action, but still releases.
        if (_trackingPointer) {
            _trackingPointer = NO;
            [self animatePressed:NO];
        }
    }
}
- (BOOL)sendAction:(SEL)action to:(id)target {
    if (_trackingPointer) {
        _trackingPointer = NO;
        [self animatePressed:NO];
    }
    return [super sendAction:action to:target];
}
- (void)setPrimary:(BOOL)primary {
    _primary = primary;
    self.contentTintColor = primary ? BawanAccentForegroundColor() : BawanColor(BawanText);
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    BOOL highlighted = self.cell.highlighted;
    if (!self.plain) {
        DrawButton(self.bounds, self.primary, self.gold, highlighted, self.enabled);
    } else if (highlighted) {
        [[BawanColor(BawanHeaderText) colorWithAlphaComponent:0.12] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
    }
    [super drawRect:dirtyRect];
}
@end

static void ActivateConstraints(NSArray<NSLayoutConstraint *> *constraints) {
    for (NSLayoutConstraint *constraint in constraints) constraint.identifier = @"bawan.layout";
    [NSLayoutConstraint activateConstraints:constraints];
}

BawanSurfaceView *BawanMakeWindowSurface(NSString *identifier, NSRect frame) {
    BawanSurfaceView *content = [[BawanSurfaceView alloc] initWithFrame:frame];
    content.identifier = identifier;
    content.fillColor = BawanColor(BawanBackground);
    content.borderColor = BawanColor(BawanBorder);
    content.textured = YES;
    content.cornerRadius = 16;
    content.wantsLayer = YES;
    content.layer.cornerRadius = 16;
    content.layer.masksToBounds = YES;
    return content;
}

BawanSurfaceView *BawanAddSurface(NSView *parent, NSString *identifier, BawanColorRole role) {
    BawanSurfaceView *view = [[BawanSurfaceView alloc] initWithFrame:NSZeroRect];
    view.identifier = identifier;
    view.fillColor = BawanColor(role);
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [parent addSubview:view];
    return view;
}

BawanActionButton *BawanAddActionButton(NSView *parent, NSString *identifier, NSString *title,
                                        id target, SEL action, BOOL primary) {
    BawanActionButton *button = [[BawanActionButton alloc] initWithFrame:NSZeroRect];
    button.identifier = identifier;
    [button setButtonType:NSButtonTypeMomentaryPushIn];
    button.bordered = NO;
    button.title = title;
    button.font = BawanLabelFont(14);
    button.primary = primary;
    button.target = target;
    button.action = action;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.focusRingType = NSFocusRingTypeExterior;
    if (parent) [parent addSubview:button];
    return button;
}

BawanChromeHeader BawanAddHeader(NSView *root, NSString *identifier, NSString *mascotIdentifier) {
    BawanSurfaceView *header = BawanAddSurface(root, identifier, BawanHeader);
    header.masthead = YES;
    BawanMascotView *mascot = [[BawanMascotView alloc] init];
    mascot.identifier = mascotIdentifier;
    mascot.translatesAutoresizingMaskIntoConstraints = NO;
    [mascot setAccessibilityElement:NO];
    [header addSubview:mascot];
    ActivateConstraints(@[
        [header.topAnchor constraintEqualToAnchor:root.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:BawanHeaderHeight],
        [mascot.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [mascot.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [mascot.widthAnchor constraintEqualToConstant:BawanBrandMarkSize],
        [mascot.heightAnchor constraintEqualToConstant:BawanBrandMarkSize]
    ]);
    return {header, mascot};
}

BawanActionButton *BawanAddHeaderButton(NSView *header, NSString *identifier, NSString *symbol,
                                        NSString *label, id target, SEL action) {
    BawanActionButton *button = BawanAddActionButton(header, identifier, @"", target, action, NO);
    button.plain = YES;
    button.image = BawanSymbol(symbol, label, 20);
    button.contentTintColor = BawanColor(BawanHeaderText);
    button.imagePosition = NSImageOnly;
    [button setAccessibilityLabel:label];
    ActivateConstraints(@[
        [button.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-BawanChromeInset],
        [button.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [button.widthAnchor constraintEqualToConstant:36],
        [button.heightAnchor constraintEqualToConstant:36]
    ]);
    return button;
}

BawanChromeFooter BawanAddFooter(NSView *root, NSString *identifier) {
    BawanSurfaceView *footer = BawanAddSurface(root, identifier, BawanBackground);
    footer.textured = YES;
    BawanSurfaceView *divider = BawanAddSurface(root, [identifier stringByAppendingString:@"-divider"], BawanBorder);
    ActivateConstraints(@[
        [divider.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [divider.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [divider.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [divider.heightAnchor constraintEqualToConstant:BawanChromeLineWidth],
        [footer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [footer.heightAnchor constraintEqualToConstant:BawanFooterHeight]
    ]);
    return {footer, divider};
}

static BawanActionButton *FooterButton(NSView *footer, NSString *identifier, NSString *title,
                                       id target, SEL action, BOOL primary) {
    BawanActionButton *button = BawanAddActionButton(footer, identifier, title, target, action, primary);
    button.wantsLayer = YES;
    button.pressFeedback = YES;
    ActivateConstraints(@[
        primary ? [button.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:BawanChromeInset] :
                  [button.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-BawanChromeInset],
        [button.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [button.widthAnchor constraintEqualToConstant:primary ? BawanFooterPrimaryWidth : BawanFooterSecondaryWidth],
        [button.heightAnchor constraintEqualToConstant:BawanFooterButtonHeight]
    ]);
    return button;
}

BawanActionButton *BawanAddFooterPrimary(NSView *footer, NSString *identifier, NSString *title, id target, SEL action) {
    return FooterButton(footer, identifier, title, target, action, YES);
}

BawanActionButton *BawanAddFooterSecondary(NSView *footer, NSString *identifier, NSString *title, id target, SEL action) {
    return FooterButton(footer, identifier, title, target, action, NO);
}

NSTextField *BawanAddFooterHint(NSView *footer, NSString *identifier, NSString *text,
                                NSView *leading, NSView *trailing) {
    NSTextField *hint = BawanLabel(text, 12, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    hint.identifier = identifier;
    hint.selectable = NO;
    hint.alignment = NSTextAlignmentCenter;
    hint.maximumNumberOfLines = 2;
    [footer addSubview:hint];
    ActivateConstraints(@[
        leading ? [hint.leadingAnchor constraintEqualToAnchor:leading.trailingAnchor constant:12] :
                  [hint.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:BawanChromeInset],
        // Without a trailing button, mirror the leading inset so the note stays centered.
        trailing ? [hint.trailingAnchor constraintEqualToAnchor:trailing.leadingAnchor constant:-12] :
                   [hint.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor
                       constant:-(leading ? BawanChromeInset + BawanFooterPrimaryWidth + 12 : BawanChromeInset)],
        [hint.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor]
    ]);
    return hint;
}
