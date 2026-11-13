#import "BawanMascotView.h"
#import "BawanAppearance.h"
#import <QuartzCore/QuartzCore.h>

namespace {
constexpr CFTimeInterval HoverDuration = 0.28;
NSString *const HoverKey = @"bawan.hover";

// Paths use the original artwork's normalized coordinates, with y pointing down.
CGPathRef EarPath(BOOL right, CGSize size, BOOL bodyCutout) {
    CGMutablePathRef path = CGPathCreateMutable();
    if (right) {
        CGPathMoveToPoint(path, nullptr, 0.590, 0.310);
        CGPathAddCurveToPoint(path, nullptr, 0.635, 0.190, 0.740, 0.040, 0.795, 0.063);
        CGPathAddCurveToPoint(path, nullptr, 0.840, 0.090, 0.850, 0.270, 0.810, 0.340);
        CGPathAddLineToPoint(path, nullptr, 0.750, bodyCutout ? 0.315 : 0.405);
        CGPathAddLineToPoint(path, nullptr, 0.600, bodyCutout ? 0.300 : 0.390);
    } else {
        CGPathMoveToPoint(path, nullptr, 0.160, 0.255);
        CGPathAddCurveToPoint(path, nullptr, 0.150, 0.150, 0.185, 0.055, 0.230, 0.065);
        CGPathAddCurveToPoint(path, nullptr, 0.310, 0.065, 0.400, 0.175, 0.435, 0.285);
        CGPathAddLineToPoint(path, nullptr, 0.400, bodyCutout ? 0.300 : 0.385);
        CGPathAddLineToPoint(path, nullptr, 0.215, bodyCutout ? 0.300 : 0.405);
    }
    CGPathCloseSubpath(path);
    CGAffineTransform scale = CGAffineTransformMakeScale(size.width, size.height);
    CGPathRef scaled = CGPathCreateCopyByTransformingPath(path, &scale);
    CGPathRelease(path);
    return scaled;
}

CGPathRef EyePath(BOOL right, CGSize size, BOOL crease) {
    CGMutablePathRef path = CGPathCreateMutable();
    if (right) {
        CGPathMoveToPoint(path, nullptr, 0.677, 0.538);
        if (crease) {
            CGPathAddCurveToPoint(path, nullptr, 0.694, 0.549, 0.720, 0.545, 0.736, 0.525);
        } else {
            CGPathAddCurveToPoint(path, nullptr, 0.676, 0.507, 0.690, 0.473, 0.714, 0.478);
            CGPathAddCurveToPoint(path, nullptr, 0.742, 0.482, 0.746, 0.521, 0.727, 0.544);
            CGPathAddCurveToPoint(path, nullptr, 0.710, 0.553, 0.690, 0.552, 0.677, 0.538);
            CGPathCloseSubpath(path);
        }
    } else {
        CGPathMoveToPoint(path, nullptr, 0.420, 0.543);
        if (crease) {
            CGPathAddCurveToPoint(path, nullptr, 0.460, 0.565, 0.518, 0.562, 0.552, 0.541);
        } else {
            CGPathAddCurveToPoint(path, nullptr, 0.432, 0.498, 0.474, 0.472, 0.510, 0.488);
            CGPathAddCurveToPoint(path, nullptr, 0.539, 0.499, 0.543, 0.530, 0.552, 0.546);
            CGPathAddCurveToPoint(path, nullptr, 0.516, 0.566, 0.455, 0.566, 0.420, 0.543);
            CGPathCloseSubpath(path);
        }
    }
    CGAffineTransform scale = CGAffineTransformMakeScale(size.width, size.height);
    CGPathRef scaled = CGPathCreateCopyByTransformingPath(path, &scale);
    CGPathRelease(path);
    return scaled;
}

NSValue *Transform(CGFloat rotation, CGFloat x = 0, CGFloat y = 0, CGFloat squash = 1) {
    CATransform3D transform = CATransform3DMakeTranslation(x, y, 0);
    transform = CATransform3DRotate(transform, rotation, 0, 0, 1);
    transform = CATransform3DScale(transform, 1, squash, 1);
    return [NSValue valueWithCATransform3D:transform];
}

CAKeyframeAnimation *Motion(NSArray<NSValue *> *values) {
    CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
    animation.values = values;
    animation.keyTimes = @[@0, @0.23, @0.50, @0.76, @1];
    animation.duration = HoverDuration;
    CAMediaTimingFunction *ease = [CAMediaTimingFunction functionWithControlPoints:0.77 :0 :0.175 :1];
    animation.timingFunctions = @[ease, ease, ease, ease];
    animation.removedOnCompletion = YES;
    return animation;
}
}

@interface BawanMascotView () {
    NSTrackingArea *_hoverArea;
    CALayer *_clip;
    CALayer *_dog;
    CALayer *_face;
    CALayer *_leftEar;
    CALayer *_rightEar;
    CALayer *_leftLid;
    CALayer *_rightLid;
    BOOL _inside;
    NSUInteger _nextMotion;
    NSUInteger _hoverGeneration;
}
@end

@implementation BawanMascotView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.image = BawanMascotImage();
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    CGImageRef bitmap = [self.image CGImageForProposedRect:nullptr context:nil hints:nil];
    _clip = [CALayer layer];
    _clip.name = @"bawan.mascot.clip";
    _dog = [CALayer layer];
    _dog.name = @"bawan.mascot.dog";
    [self.layer addSublayer:_clip];
    [_clip addSublayer:_dog];
    NSMutableArray<CALayer *> *parts = [NSMutableArray array];
    for (NSString *name in @[@"bawan.mascot.left-ear", @"bawan.mascot.right-ear", @"bawan.mascot.face"]) {
        CALayer *part = [CALayer layer];
        part.name = name;
        part.contents = (__bridge id)bitmap;
        part.contentsGravity = kCAGravityResize;
        part.contentsScale = 2;
        part.mask = [CAShapeLayer layer];
        [_dog addSublayer:part];
        [parts addObject:part];
    }
    _leftEar = parts[0];
    _rightEar = parts[1];
    _face = parts[2];
    _leftEar.anchorPoint = CGPointMake(0.29, 0.35);
    _rightEar.anchorPoint = CGPointMake(0.71, 0.34);
    _leftLid = [self eyelid:NO];
    _rightLid = [self eyelid:YES];
    [_dog addSublayer:_leftLid];
    [_dog addSublayer:_rightLid];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
        selector:@selector(accessibilityChanged:) name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
    return self;
}

- (CALayer *)eyelid:(BOOL)right {
    CALayer *lid = [CALayer layer];
    lid.name = right ? @"bawan.mascot.right-lid" : @"bawan.mascot.left-lid";
    lid.opacity = 0;
    CAShapeLayer *skin = [CAShapeLayer layer];
    skin.fillColor = BawanRGB(0xFFBA43).CGColor;
    CAShapeLayer *crease = [CAShapeLayer layer];
    crease.fillColor = nil;
    crease.strokeColor = BawanRGB(0x38271C).CGColor;
    crease.lineWidth = 0.7;
    crease.lineCap = kCALineCapRound;
    [lid addSublayer:skin];
    [lid addSublayer:crease];
    return lid;
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _clip.frame = NSInsetRect(self.bounds, 1.8, 1.8);
    CAShapeLayer *clipMask = (CAShapeLayer *)_clip.mask;
    if (!clipMask) { clipMask = [CAShapeLayer layer]; _clip.mask = clipMask; }
    CGPathRef circle = CGPathCreateWithEllipseInRect(_clip.bounds, nullptr);
    clipMask.path = circle;
    CGPathRelease(circle);
    _dog.frame = NSInsetRect(_clip.bounds, 2.2, 2.2);
    CGSize size = _dog.bounds.size;
    for (CALayer *part in @[_leftEar, _rightEar, _face]) {
        part.bounds = _dog.bounds;
        part.position = CGPointMake(size.width * part.anchorPoint.x, size.height * part.anchorPoint.y);
        ((CAShapeLayer *)part.mask).frame = part.bounds;
    }
    CGPathRef left = EarPath(NO, size, NO);
    CGPathRef right = EarPath(YES, size, NO);
    ((CAShapeLayer *)_leftEar.mask).path = left;
    ((CAShapeLayer *)_rightEar.mask).path = right;
    CGPathRelease(left);
    CGPathRelease(right);
    CGMutablePathRef body = CGPathCreateMutable();
    CGPathAddRect(body, nullptr, _dog.bounds);
    left = EarPath(NO, size, YES);
    right = EarPath(YES, size, YES);
    CGPathAddPath(body, nullptr, left);
    CGPathAddPath(body, nullptr, right);
    ((CAShapeLayer *)_face.mask).fillRule = kCAFillRuleEvenOdd;
    ((CAShapeLayer *)_face.mask).path = body;
    CGPathRelease(left);
    CGPathRelease(right);
    CGPathRelease(body);
    for (NSUInteger index = 0; index < 2; ++index) {
        CALayer *lid = index ? _rightLid : _leftLid;
        lid.frame = _dog.bounds;
        for (NSUInteger item = 0; item < 2; ++item) {
            CAShapeLayer *shape = (CAShapeLayer *)lid.sublayers[item];
            shape.frame = lid.bounds;
            shape.contentsScale = self.window.backingScaleFactor ?: 2;
            CGPathRef path = EyePath(index != 0, size, item != 0);
            shape.path = path;
            CGPathRelease(path);
        }
    }
    [CATransaction commit];
}

- (void)drawRect:(NSRect)dirtyRect { BawanDrawMedallionBase(self.bounds); }
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverArea) [self removeTrackingArea:_hoverArea];
    _hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:_hoverArea];
}
- (void)mouseEntered:(NSEvent *)event {
    if (_inside) return;
    _inside = YES;
    [self playNextAnimation];
}
- (void)mouseDown:(NSEvent *)event {
    _inside = YES;
    [self playNextAnimation];
}
- (void)playNextAnimation {
    if (!self.window.visible || self.hiddenOrHasHiddenAncestor ||
        NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) return;
    [self layoutSubtreeIfNeeded];
    // A click can replace an unfinished hover. Continue from what is visible.
    NSValue *dogStart = [NSValue valueWithCATransform3D:(_dog.presentationLayer ?: _dog).transform];
    NSValue *leftStart = [NSValue valueWithCATransform3D:(_leftEar.presentationLayer ?: _leftEar).transform];
    NSValue *rightStart = [NSValue valueWithCATransform3D:(_rightEar.presentationLayer ?: _rightEar).transform];
    float leftOpacity = (_leftLid.presentationLayer ?: _leftLid).opacity;
    float rightOpacity = (_rightLid.presentationLayer ?: _rightLid).opacity;
    NSUInteger generation = ++_hoverGeneration;
    __weak BawanMascotView *weakSelf = self;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [CATransaction setCompletionBlock:^{
        BawanMascotView *view = weakSelf;
        // An earlier completion must not cancel a later hover or click.
        if (view && view->_hoverGeneration == generation) [view clearHoverAnimations];
    }];
    NSValue *rest = Transform(0);
    NSArray<NSValue *> *values;
    NSString *name;
    switch (_nextMotion++ % 3) {
        case 0:
            name = @"tilt";
            values = @[dogStart, Transform(-0.045), Transform(0.025), Transform(-0.01), rest];
            break;
        case 1:
            name = @"hop";
            values = @[dogStart, Transform(0, 0, -1.6), Transform(0, 0, 0.35), Transform(0, 0, -0.15), rest];
            break;
        default:
            name = @"shake";
            values = @[dogStart, Transform(-0.025, -1.2), Transform(0.025, 1.2), Transform(-0.01, -0.5), rest];
            break;
    }
    CAKeyframeAnimation *motion = Motion(values);
    [motion setValue:name forKey:@"bawan.motion"];
    [_dog addAnimation:motion forKey:HoverKey];
    [_leftEar addAnimation:Motion(@[leftStart, Transform(-0.07, 0, 0, 0.94), Transform(0.025), Transform(-0.01), rest]) forKey:HoverKey];
    [_rightEar addAnimation:Motion(@[rightStart, Transform(0.06, 0, 0, 0.95), Transform(-0.03), Transform(0.01), rest]) forKey:HoverKey];
    CAKeyframeAnimation *blink = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    blink.values = @[@(leftOpacity), @(leftOpacity), @1, @1, @0, @0];
    blink.keyTimes = @[@0, @0.25, @0.4, @0.5, @0.65, @1];
    blink.duration = HoverDuration;
    blink.removedOnCompletion = YES;
    [_leftLid addAnimation:blink forKey:HoverKey];
    blink.values = @[@(rightOpacity), @(rightOpacity), @1, @1, @0, @0];
    [_rightLid addAnimation:blink forKey:HoverKey];
    [CATransaction commit];
}
- (void)mouseExited:(NSEvent *)event { [self resetHoverAnimation]; }
- (void)resetHoverAnimation {
    _inside = NO;
    ++_hoverGeneration;
    [self clearHoverAnimations];
}
- (void)clearHoverAnimations {
    for (CALayer *part in @[_dog, _leftEar, _rightEar, _leftLid, _rightLid]) {
        [part removeAnimationForKey:HoverKey];
    }
}
- (void)viewWillMoveToWindow:(NSWindow *)window {
    if (window != self.window) [self resetHoverAnimation];
    [super viewWillMoveToWindow:window];
}
- (void)viewDidHide { [super viewDidHide]; [self resetHoverAnimation]; }
- (void)viewWillStartLiveResize { [super viewWillStartLiveResize]; [self resetHoverAnimation]; }
- (void)accessibilityChanged:(NSNotification *)notification {
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) [self resetHoverAnimation];
}
- (void)dealloc {
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}
@end
