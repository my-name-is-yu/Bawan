#import "TranslationPanel.h"
#import <QuartzCore/CALayer.h>
#import <QuartzCore/CAAnimation.h>
#import <QuartzCore/CAMediaTimingFunction.h>
#import <QuartzCore/CATransaction.h>

#include <algorithm>

namespace {
enum ColorRole { Background, Surface, Text, SecondaryText, Border, Button, Accent };

NSColor *RGB(unsigned value) {
    return [NSColor colorWithSRGBRed:((value >> 16) & 255) / 255.0
                              green:((value >> 8) & 255) / 255.0
                               blue:(value & 255) / 255.0 alpha:1];
}

NSColor *Color(ColorRole role) {
    static NSArray<NSColor *> *colors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const unsigned light[] = {0xFAFAFA, 0xF1F2F4, 0x202124, 0x5F626B, 0xDEDFE4, 0xE7E8ED, 0x635BE9};
        const unsigned dark[] = {0x202124, 0x252629, 0xF4F4F5, 0xB8BAC2, 0x42434A, 0x323338, 0x7775F8};
        NSArray<NSAppearanceName> *appearances = @[
            NSAppearanceNameAccessibilityHighContrastAqua, NSAppearanceNameAccessibilityHighContrastDarkAqua,
            NSAppearanceNameAqua, NSAppearanceNameDarkAqua];
        NSMutableArray<NSColor *> *palette = [NSMutableArray array];
        for (NSUInteger i = 0; i < sizeof(light) / sizeof(light[0]); ++i) {
            NSColor *lightColor = RGB(light[i]);
            NSColor *darkColor = RGB(dark[i]);
            NSColor *contrastLight = i == Border ? RGB(0x757780) :
                (i == SecondaryText ? RGB(0x44464D) : lightColor);
            NSColor *contrastDark = i == Border ? RGB(0x8A8C94) :
                (i == SecondaryText ? RGB(0xD0D1D6) : darkColor);
            [palette addObject:[NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
                NSString *match = [appearance bestMatchFromAppearancesWithNames:appearances];
                if ([match isEqualToString:NSAppearanceNameAccessibilityHighContrastAqua]) return contrastLight;
                if ([match isEqualToString:NSAppearanceNameAccessibilityHighContrastDarkAqua]) return contrastDark;
                return [match isEqualToString:NSAppearanceNameDarkAqua] ? darkColor : lightColor;
            }]];
        }
        colors = [palette copy];
    });
    return colors[role];
}

void DrawButton(NSRect frame, BOOL primary, BOOL highlighted, BOOL enabled) {
    NSColor *fill = Color(primary ? Accent : Button);
    if (!enabled) fill = [fill colorWithAlphaComponent:0.4];
    else if (highlighted) fill = [fill blendedColorWithFraction:0.15 ofColor:Color(Text)];
    [fill setFill];
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(frame, 0.5, 0.5)
                                                       xRadius:10 yRadius:10];
    [path fill];
    if (!primary) {
        [Color(Border) setStroke];
        path.lineWidth = 1;
        [path stroke];
    }
}

NSTextField *Label(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

NSImage *Symbol(NSString *name, NSString *description, CGFloat size) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:description];
    return [image imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightMedium]];
}
} // namespace

@interface LorePanel : NSPanel
@property(nonatomic, copy) void (^onTranslateKey)(void);
@end

@implementation LorePanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
- (void)cancelOperation:(id)sender { [self close]; }
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags modifiers = event.modifierFlags &
        (NSEventModifierFlagCommand | NSEventModifierFlagShift |
         NSEventModifierFlagControl | NSEventModifierFlagOption);
    NSString *key = event.charactersIgnoringModifiers;
    if (modifiers == NSEventModifierFlagCommand &&
        ([key isEqualToString:@"\r"] || [key isEqualToString:@"\n"])) {
        if (self.onTranslateKey) self.onTranslateKey();
        return YES;
    }
    return [super performKeyEquivalent:event];
}
@end

// These surfaces draw with dynamic NSColors, so appearance changes require no
// alternate view tree, image cache, notification observer or background work.
@interface LoreSurface : NSView
@property(nonatomic, strong) NSColor *fillColor;
@property(nonatomic, strong) NSColor *borderColor;
@property(nonatomic) CGFloat cornerRadius;
@property(nonatomic) BOOL draggable;
@end

@implementation LoreSurface
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return self.draggable; }
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect frame = self.borderColor ? NSInsetRect(self.bounds, 0.5, 0.5) : self.bounds;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:frame
                                                       xRadius:self.cornerRadius yRadius:self.cornerRadius];
    [self.fillColor setFill];
    [path fill];
    if (self.borderColor) {
        [self.borderColor setStroke];
        path.lineWidth = 1;
        [path stroke];
    }
}
@end

@interface LoreButton : NSButton {
    BOOL _trackingPointer;
}
@property(nonatomic) BOOL primary;
@property(nonatomic) BOOL plain;
@property(nonatomic) BOOL pressFeedback;
- (void)resetPressFeedback;
@end

@implementation LoreButton
// Our bezel fills the bounds; native button ornament insets must not enlarge it.
- (NSRect)alignmentRectForFrame:(NSRect)frame { return frame; }
- (NSRect)frameForAlignmentRect:(NSRect)rect { return rect; }
- (void)resetPressFeedback {
    _trackingPointer = NO;
    [self.layer removeAnimationForKey:@"lore.press"];
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
    // One replaceable finite animation; a rapid reversal starts at presentation.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.transform = target;
    [layer addAnimation:animation forKey:@"lore.press"];
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
    // Never wait for motion before translating, cancelling or copying.
    return [super sendAction:action to:target];
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    BOOL highlighted = self.cell.highlighted;
    if (!self.plain || highlighted) DrawButton(self.bounds, self.primary, highlighted, self.enabled);
    [super drawRect:dirtyRect];
}
@end

@interface LoreTextView : NSTextView
@property(nonatomic, copy) NSString *placeholder;
@end

@implementation LoreTextView
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (self.string.length == 0) {
        [self.placeholder drawInRect:NSInsetRect(self.bounds, 1, 1) withAttributes:
            @{NSFontAttributeName:self.font, NSForegroundColorAttributeName:Color(SecondaryText)}];
    }
}
@end

@interface TranslationPanel () <NSWindowDelegate, NSTextViewDelegate> {
    LorePanel *_panel;
    LoreTextView *_source;
    LoreTextView *_output;
    LoreButton *_swap;
    lore::Direction _inputDirection;
    lore::Direction _outputDirection;
    NSTextField *_status;
    NSTextField *_instructions;
    NSLayoutConstraint *_messageSpacing;
    LoreButton *_translate;
    LoreButton *_copy;
    NSImage *_copyIcon;
    NSImage *_copiedIcon;
    BOOL _available;
    BOOL _busy;
}
@end

@implementation TranslationPanel

static LoreSurface *SurfaceView(NSView *parent, NSString *identifier, ColorRole role) {
    LoreSurface *view = [[LoreSurface alloc] initWithFrame:NSZeroRect];
    view.identifier = identifier;
    view.fillColor = Color(role);
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [parent addSubview:view];
    return view;
}

static void AddConstraints(NSArray<NSLayoutConstraint *> *constraints) {
    for (NSLayoutConstraint *constraint in constraints) constraint.identifier = @"lore.layout";
    [NSLayoutConstraint activateConstraints:constraints];
}

static LoreButton *ButtonView(NSView *parent, NSString *identifier, NSString *title,
                               id target, SEL action, BOOL primary, BOOL plain) {
    LoreButton *button = [[LoreButton alloc] initWithFrame:NSZeroRect];
    button.identifier = identifier;
    [button setButtonType:NSButtonTypeMomentaryPushIn];
    button.bordered = NO;
    button.title = title;
    button.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    button.contentTintColor = primary ? NSColor.whiteColor : Color(Text);
    button.primary = primary;
    button.plain = plain;
    button.target = target;
    button.action = action;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.focusRingType = NSFocusRingTypeExterior;
    [parent addSubview:button];
    return button;
}

static NSScrollView *TextArea(NSView *parent, LoreTextView *__strong *textView, BOOL editable,
                               NSString *identifier, NSString *label, NSString *placeholder) {
    // Start the clip view and document at the same width. Otherwise the first
    // autoresize adds the initial document width and silently clips long lines.
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 280, 140)];
    scroll.borderType = NSNoBorder;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    scroll.drawsBackground = NO;
    scroll.contentView.drawsBackground = NO;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    LoreTextView *text = [[LoreTextView alloc] initWithFrame:NSMakeRect(0, 0, 280, 140)];
    text.identifier = identifier;
    text.placeholder = placeholder;
    text.editable = editable;
    text.selectable = YES;
    text.richText = NO;
    text.font = [NSFont systemFontOfSize:16];
    text.textColor = Color(editable ? SecondaryText : Text);
    text.insertionPointColor = Color(Text);
    text.drawsBackground = NO;
    text.textContainerInset = NSMakeSize(0, 0);
    text.textContainer.lineFragmentPadding = 0;
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.lineSpacing = 5;
    text.defaultParagraphStyle = paragraph;
    text.verticallyResizable = YES;
    text.horizontallyResizable = NO;
    text.minSize = NSMakeSize(0, 0);
    text.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    text.autoresizingMask = NSViewWidthSizable;
    text.textContainer.containerSize = NSMakeSize(280, CGFLOAT_MAX);
    text.textContainer.widthTracksTextView = YES;
    text.automaticQuoteSubstitutionEnabled = NO;
    text.automaticDashSubstitutionEnabled = NO;
    text.automaticSpellingCorrectionEnabled = NO;
    text.automaticTextReplacementEnabled = NO;
    text.continuousSpellCheckingEnabled = NO;
    text.grammarCheckingEnabled = NO;
    text.allowsUndo = editable;
    [text setAccessibilityLabel:label];
    scroll.documentView = text;
    [parent addSubview:scroll];
    *textView = text;
    return scroll;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _panel = [[LorePanel alloc] initWithContentRect:NSMakeRect(0, 0, 720, 500)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                  NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    _panel.title = @"Lore";
    _panel.titleVisibility = NSWindowTitleHidden;
    _panel.titlebarAppearsTransparent = YES;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.opaque = NO;
    _panel.hasShadow = YES;
    _panel.movableByWindowBackground = YES;
    _panel.minSize = NSMakeSize(640, 420);
    [_panel setFrame:NSMakeRect(0, 0, 720, 500) display:NO];
    for (NSNumber *kind in @[@(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton)]) {
        [_panel standardWindowButton:static_cast<NSWindowButton>(kind.integerValue)].hidden = YES;
    }
    _panel.releasedWhenClosed = NO;
    _panel.hidesOnDeactivate = NO;
    _panel.floatingPanel = YES;
    _panel.becomesKeyOnlyIfNeeded = YES;
    _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorFullScreenAuxiliary;
    _panel.delegate = self;
    __weak TranslationPanel *weakSelf = self;
    _panel.onTranslateKey = ^{ [weakSelf translate:nil]; };

    LoreSurface *content = [[LoreSurface alloc] initWithFrame:NSMakeRect(0, 0, 720, 500)];
    content.identifier = @"lore-panel";
    content.fillColor = Color(Background);
    content.borderColor = Color(Border);
    content.cornerRadius = 16;
    content.wantsLayer = YES;
    content.layer.cornerRadius = 16;
    content.layer.masksToBounds = YES;
    _panel.contentView = content;

    LoreSurface *header = SurfaceView(content, @"header", Surface);
    header.draggable = YES;
    LoreSurface *headerLine = SurfaceView(content, @"header-divider", Border);
    LoreSurface *footer = SurfaceView(content, @"footer", Surface);
    LoreSurface *footerLine = SurfaceView(content, @"footer-divider", Border);
    LoreSurface *dividerTop = SurfaceView(content, @"pane-divider-top", Border);
    LoreSurface *dividerBottom = SurfaceView(content, @"pane-divider-bottom", Border);

    NSImageView *mark = [[NSImageView alloc] initWithFrame:NSZeroRect];
    mark.image = Symbol(@"app", @"Lore", 20);
    mark.contentTintColor = Color(Accent);
    mark.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:mark];
    NSTextField *name = Label(@"Lore", 20, NSFontWeightSemibold, Color(Text));
    [header addSubview:name];
    LoreButton *settings = ButtonView(header, @"settings", @"", self, @selector(openSettings:), NO, YES);
    settings.image = Symbol(@"gearshape", @"Settings", 17);
    settings.imagePosition = NSImageOnly;
    settings.toolTip = @"Settings";
    [settings setAccessibilityLabel:@"Settings"];
    LoreButton *dismiss = ButtonView(header, @"dismiss", @"Esc", self, @selector(dismiss:), NO, YES);
    dismiss.contentTintColor = Color(SecondaryText);
    dismiss.toolTip = @"Close (Esc)";
    [dismiss setAccessibilityLabel:@"Close translator"];

    _swap = ButtonView(content, @"swap", @"", self, @selector(swapText:), NO, NO);
    _swap.image = Symbol(@"arrow.right.arrow.left", @"", 16);
    _swap.imagePosition = NSImageOnly;
    _swap.toolTip = @"Swap text and translate back";
    [_swap setAccessibilityLabel:@"Swap text and translate back"];

    NSScrollView *sourceScroll = TextArea(content, &_source, YES, @"source", @"Source text",
                                         @"Type or paste text");
    NSScrollView *outputScroll = TextArea(content, &_output, NO, @"output", @"Translation",
                                         @"");
    _source.delegate = self;

    _instructions = Label(@"", 11, NSFontWeightRegular, Color(SecondaryText));
    _instructions.identifier = @"instructions";
    _instructions.maximumNumberOfLines = 2;
    _status = Label(@"", 11, NSFontWeightRegular, Color(SecondaryText));
    _status.identifier = @"status";
    _status.maximumNumberOfLines = 3;
    [_status setAccessibilityLabel:@"Translation status"];
    _status.hidden = YES;
    NSStackView *messages = [NSStackView stackViewWithViews:@[_instructions, _status]];
    messages.identifier = @"messages";
    messages.orientation = NSUserInterfaceLayoutOrientationVertical;
    messages.alignment = NSLayoutAttributeLeading;
    messages.distribution = NSStackViewDistributionFill;
    messages.spacing = 8;
    messages.detachesHiddenViews = YES;
    [content addSubview:messages];
    _messageSpacing = [sourceScroll.bottomAnchor constraintEqualToAnchor:messages.topAnchor];

    _translate = ButtonView(footer, @"translate", @"Translate  ⌘↵", self, @selector(performPrimaryAction:), NO, NO);
    _translate.toolTip = @"Translate (⌘Return); cancel while translating";
    _copy = ButtonView(footer, @"copy", @"Copy Translation", self, @selector(copyOutput:), YES, NO);
    _copyIcon = Symbol(@"doc.on.doc", @"", 13);
    _copiedIcon = Symbol(@"checkmark", @"", 13);
    _copy.image = _copyIcon;
    _copy.imagePosition = NSImageLeft;
    _copy.imageHugsTitle = YES;
    // Only the two footer actions need their own composited press feedback.
    for (LoreButton *button in @[_translate, _copy]) {
        button.wantsLayer = YES;
        button.pressFeedback = YES;
    }

    AddConstraints(@[
        [header.topAnchor constraintEqualToAnchor:content.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:48],
        [headerLine.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [headerLine.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [headerLine.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [headerLine.heightAnchor constraintEqualToConstant:1],
        [mark.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:24],
        [mark.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [mark.widthAnchor constraintEqualToConstant:24],
        [mark.heightAnchor constraintEqualToConstant:24],
        [name.leadingAnchor constraintEqualToAnchor:mark.trailingAnchor constant:8],
        [name.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [dismiss.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-24],
        [dismiss.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [dismiss.widthAnchor constraintEqualToConstant:48],
        [dismiss.heightAnchor constraintEqualToConstant:32],
        [settings.trailingAnchor constraintEqualToAnchor:dismiss.leadingAnchor constant:-8],
        [settings.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [settings.widthAnchor constraintEqualToConstant:32],
        [settings.heightAnchor constraintEqualToConstant:32],
        [_swap.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [_swap.centerYAnchor constraintEqualToAnchor:sourceScroll.centerYAnchor],
        [_swap.widthAnchor constraintEqualToConstant:32],
        [_swap.heightAnchor constraintEqualToConstant:32],
        [dividerTop.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [dividerTop.topAnchor constraintEqualToAnchor:sourceScroll.topAnchor],
        [dividerTop.bottomAnchor constraintEqualToAnchor:_swap.topAnchor constant:-8],
        [dividerTop.widthAnchor constraintEqualToConstant:1],
        [dividerBottom.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [dividerBottom.topAnchor constraintEqualToAnchor:_swap.bottomAnchor constant:8],
        [dividerBottom.bottomAnchor constraintEqualToAnchor:sourceScroll.bottomAnchor],
        [dividerBottom.widthAnchor constraintEqualToConstant:1],
        [sourceScroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [sourceScroll.trailingAnchor constraintEqualToAnchor:content.centerXAnchor constant:-24],
        [sourceScroll.topAnchor constraintEqualToAnchor:headerLine.bottomAnchor constant:24],
        _messageSpacing,
        [outputScroll.leadingAnchor constraintEqualToAnchor:content.centerXAnchor constant:24],
        [outputScroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [outputScroll.topAnchor constraintEqualToAnchor:sourceScroll.topAnchor],
        [outputScroll.bottomAnchor constraintEqualToAnchor:sourceScroll.bottomAnchor],
        [messages.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [messages.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [messages.bottomAnchor constraintEqualToAnchor:footerLine.topAnchor constant:-24],
        [_instructions.widthAnchor constraintEqualToAnchor:messages.widthAnchor],
        [_status.widthAnchor constraintEqualToAnchor:messages.widthAnchor],
        [footerLine.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [footerLine.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [footerLine.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [footerLine.heightAnchor constraintEqualToConstant:1],
        [footer.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [footer.heightAnchor constraintEqualToConstant:64],
        [_copy.centerXAnchor constraintEqualToAnchor:outputScroll.centerXAnchor],
        [_copy.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [_copy.widthAnchor constraintEqualToConstant:168],
        [_copy.heightAnchor constraintEqualToConstant:32],
        [_translate.centerXAnchor constraintEqualToAnchor:sourceScroll.centerXAnchor],
        [_translate.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [_translate.widthAnchor constraintEqualToAnchor:_copy.widthAnchor],
        [_translate.heightAnchor constraintEqualToAnchor:_copy.heightAnchor]
    ]);
    [self setShortcutAvailable:NO];
    [self updateButtons];
    return self;
}

- (void)positionNearPointer {
    NSPoint pointer = NSEvent.mouseLocation;
    NSScreen *screen = NSScreen.mainScreen;
    for (NSScreen *candidate in NSScreen.screens) {
        if (NSPointInRect(pointer, candidate.frame)) { screen = candidate; break; }
    }
    if (!screen) return;
    NSRect visible = NSInsetRect(screen.visibleFrame, 8, 8);
    NSRect frame = _panel.frame;
    frame.size.width = std::min(frame.size.width, visible.size.width);
    frame.size.height = std::min(frame.size.height, visible.size.height);
    frame.origin.x = std::clamp(pointer.x + 16, NSMinX(visible), NSMaxX(visible) - frame.size.width);
    frame.origin.y = std::clamp(pointer.y - frame.size.height - 16,
                               NSMinY(visible), NSMaxY(visible) - frame.size.height);
    [_panel setFrame:frame display:NO];
}

- (void)showForSelection:(NSString *)text {
    _inputDirection = lore::Direction::Automatic;
    _source.string = text;
    // A newly selected passage starts a new editing session, not an undo history
    // of every passage translated since the resident panel was first created.
    [_source.undoManager removeAllActions];
    [self setOutput:@"" direction:lore::Direction::Automatic];
    [self showWithoutChangingInput];
}

- (void)showWithoutChangingInput {
    [self positionNearPointer];
    [_panel orderFrontRegardless];
}

- (void)setShortcutAvailable:(BOOL)available {
    _instructions.stringValue = available ? @"" :
        @"Enable Double ⌘C in Settings to translate selected text.";
    _instructions.hidden = available;
    [self updateMessageSpacing];
}

- (void)updateMessageSpacing {
    _messageSpacing.constant = (_instructions.hidden && _status.hidden) ? 0 : -16;
}

- (void)showForManualInput {
    [self positionNearPointer];
    [NSApp activateIgnoringOtherApps:YES];
    [_panel makeKeyAndOrderFront:nil];
    [_panel makeFirstResponder:_source];
}

- (void)setAvailable:(BOOL)available busy:(BOOL)busy status:(NSString *)status {
    _available = available;
    _busy = busy;
    _status.stringValue = status;
    _status.hidden = status.length == 0;
    [self updateMessageSpacing];
    [self updateButtons];
}

- (void)setOutput:(NSString *)output direction:(lore::Direction)direction {
    _outputDirection = direction;
    if (![_output.string isEqualToString:output]) {
        [self resetCopyFeedback];
        _output.string = output;
        [_output scrollRangeToVisible:NSMakeRange(output.length, 0)];
    }
    [self updateButtons];
}

- (void)updateButtons {
    BOOL hasInput = [_source.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
    BOOL hasOutput = _output.string.length > 0;
    _translate.enabled = _busy || (_available && hasInput);
    _translate.title = _busy ? @"Cancel" : (hasOutput ? @"Retranslate  ⌘↵" : @"Translate  ⌘↵");
    _copy.enabled = hasOutput;
    _swap.enabled = _available && !_busy && hasOutput && _outputDirection != lore::Direction::Automatic;
}

- (void)translate:(id)sender {
    BOOL hasInput = [_source.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
    if (_available && hasInput && self.onTranslate) self.onTranslate(_source.string, _inputDirection);
}

- (void)swapText:(id)sender {
    if (!_swap.enabled) return;
    _inputDirection = _outputDirection == lore::Direction::EnglishToJapanese ?
        lore::Direction::JapaneseToEnglish : lore::Direction::EnglishToJapanese;
    _source.string = _output.string;
    [_source.undoManager removeAllActions];
    [_source scrollRangeToVisible:NSMakeRange(0, 0)];
    [self setOutput:@"" direction:lore::Direction::Automatic];
    [self translate:nil];
}

- (void)performPrimaryAction:(id)sender {
    if (_busy) { if (self.onCancel) self.onCancel(); }
    else [self translate:sender];
}

- (void)openSettings:(id)sender { if (self.onSettings) self.onSettings(); }
- (void)dismiss:(id)sender { [_panel close]; }

- (void)copyOutput:(id)sender {
    if (_output.string.length == 0) return;
    [self resetCopyFeedback];
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    if ([pasteboard writeObjects:@[_output.string]]) {
        _copy.title = @"Copied";
        _copy.image = _copiedIcon;
    }
}

- (void)resetCopyFeedback {
    if (_copy.image == _copyIcon) return;
    // Keep confirmation until the content changes or the panel closes. No timer,
    // delayed block, toast view or stored copy of the translation is necessary.
    _copy.title = @"Copy Translation";
    _copy.image = _copyIcon;
}

- (void)textDidChange:(NSNotification *)notification {
    _inputDirection = lore::Direction::Automatic;
    _source.needsDisplay = YES;
    [self updateButtons];
}
- (void)windowWillClose:(NSNotification *)notification {
    [_translate resetPressFeedback];
    [_copy resetPressFeedback];
    [self resetCopyFeedback];
    if (self.onClose) self.onClose();
}
- (void)close { [_panel close]; }
@end
