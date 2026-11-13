#import "TranslationPanel.h"
#import "SettingsViewController.h"
#import "LoreAppearance.h"
#import <QuartzCore/CALayer.h>
#import <QuartzCore/CAAnimation.h>
#import <QuartzCore/CAMediaTimingFunction.h>
#import <QuartzCore/CATransaction.h>

#include <algorithm>

namespace {
void DrawButton(NSRect frame, BOOL primary, BOOL gold, BOOL highlighted, BOOL enabled) {
    NSColor *fill = primary ? LorePrimaryButtonFill(highlighted) : LoreColor(gold ? LoreGold : LoreBackground);
    if (!enabled) fill = [fill colorWithAlphaComponent:0.4];
    else if (highlighted && !primary) fill = [fill blendedColorWithFraction:0.12 ofColor:LoreColor(LoreText)];
    NSRect face = NSInsetRect(frame, 1, 1);
    face.size.height -= 3;
    NSBezierPath *path = gold ? LoreCutCornerPath(face) :
        [NSBezierPath bezierPathWithRoundedRect:face xRadius:8 yRadius:8];
    if (enabled) {
        // Every framed action shares the same hard shadow, including cut corners.
        NSBezierPath *shadow = [path copy];
        NSAffineTransform *offset = [NSAffineTransform transform];
        [offset translateXBy:0 yBy:3];
        [shadow transformUsingAffineTransform:offset];
        [LoreColor(LoreBorder) setFill];
        [shadow fill];
    }
    [fill setFill];
    [path fill];
    [LoreColor(LoreBorder) setStroke];
    path.lineWidth = 1.5;
    [path stroke];
}

NSTextField *Label(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = weight >= NSFontWeightMedium ? LoreLabelFont(size) : LoreBodyFont(size);
    label.textColor = color;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

} // namespace

@interface LorePanel : NSPanel
@property(nonatomic, copy) void (^onTranslateKey)(void);
@property(nonatomic, copy) void (^onCopyKey)(void);
@property(nonatomic, copy) void (^onEscape)(void);
@end

@implementation LorePanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
- (NSUndoManager *)undoManager {
    // Keep the translator's history while Settings owns the responder chain.
    if ([self.contentView.identifier isEqualToString:@"lore-settings"]) return nil;
    return [super undoManager];
}
- (void)cancelOperation:(id)sender { if (self.onEscape) self.onEscape(); }
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags modifiers = event.modifierFlags &
        (NSEventModifierFlagCommand | NSEventModifierFlagShift |
         NSEventModifierFlagControl | NSEventModifierFlagOption);
    NSString *key = event.charactersIgnoringModifiers;
    if (modifiers == NSEventModifierFlagCommand && [key.lowercaseString isEqualToString:@"w"]) {
        [self performClose:nil];
        return YES;
    }
    if (modifiers == NSEventModifierFlagCommand &&
        ([key isEqualToString:@"\r"] || [key isEqualToString:@"\n"])) {
        if (self.onTranslateKey) self.onTranslateKey();
        return YES;
    }
    if (modifiers == (NSEventModifierFlagCommand | NSEventModifierFlagShift) &&
        [key.lowercaseString isEqualToString:@"c"]) {
        if (self.onCopyKey) self.onCopyKey();
        return YES;
    }
    return [super performKeyEquivalent:event];
}
@end

// Appearance changes reuse the same surfaces, constraints and static art.
@interface LoreSurfaceView : NSView
@property(nonatomic, strong) NSColor *fillColor;
@property(nonatomic, strong) NSColor *borderColor;
@property(nonatomic) CGFloat cornerRadius;
@property(nonatomic) BOOL draggable;
@property(nonatomic) BOOL textured;
@property(nonatomic) BOOL masthead;
@property(nonatomic) BOOL cutCorners;
@end

@implementation LoreSurfaceView
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return self.draggable; }
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    if (self.masthead) { LoreDrawHeader(self.bounds); return; }
    NSRect frame = self.borderColor ? NSInsetRect(self.bounds, 0.75, 0.75) : self.bounds;
    NSBezierPath *path;
    if (self.cutCorners) {
        path = LoreCutCornerPath(frame);
    } else {
        path = [NSBezierPath bezierPathWithRoundedRect:frame xRadius:self.cornerRadius yRadius:self.cornerRadius];
    }
    [self.fillColor setFill];
    [path fill];
    if (self.textured) {
        [NSGraphicsContext saveGraphicsState];
        [path addClip];
        LoreDrawPaper(self.bounds);
        [NSGraphicsContext restoreGraphicsState];
    }
    if (self.borderColor) {
        [self.borderColor setStroke];
        path.lineWidth = 1.5;
        [path stroke];
    }
}
@end

@interface LoreActionButton : NSButton {
    BOOL _trackingPointer;
}
@property(nonatomic) BOOL primary;
@property(nonatomic) BOOL gold;
@property(nonatomic) BOOL plain;
@property(nonatomic) BOOL pressFeedback;
- (void)resetPressFeedback;
@end

@implementation LoreActionButton
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
    if (!self.plain) {
        DrawButton(self.bounds, self.primary, self.gold, highlighted, self.enabled);
    } else if (highlighted) {
        [[LoreColor(LoreHeaderText) colorWithAlphaComponent:0.12] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
    }
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
            @{NSFontAttributeName:self.font, NSForegroundColorAttributeName:LoreColor(LoreSecondaryText)}];
    }
}
@end

@interface LoreMascotView : NSImageView
@end
@implementation LoreMascotView
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect { LoreDrawMedallion(self.bounds); }
@end

@interface TranslationPanel () <NSWindowDelegate, NSTextViewDelegate> {
    LorePanel *_panel;
    NSView *_translationContent;
    SettingsViewController *_settings;
    __weak NSResponder *_translationResponder;
    LoreTextView *_source;
    LoreTextView *_output;
    LoreActionButton *_swap;
    lore::Direction _inputDirection;
    lore::Direction _outputDirection;
    NSTextField *_status;
    NSTextField *_instructions;
    NSTextField *_sourceLanguage;
    NSTextField *_outputLanguage;
    NSTextField *_shortcutHint;
    NSLayoutConstraint *_messageSpacing;
    LoreActionButton *_translate;
    LoreActionButton *_copy;
    NSImage *_copyIcon;
    NSImage *_copiedIcon;
    BOOL _available;
    BOOL _busy;
    BOOL _sourceEditedSinceRequest;
}
@end

@implementation TranslationPanel

static LoreSurfaceView *SurfaceView(NSView *parent, NSString *identifier, LoreColorRole role) {
    LoreSurfaceView *view = [[LoreSurfaceView alloc] initWithFrame:NSZeroRect];
    view.identifier = identifier;
    view.fillColor = LoreColor(role);
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [parent addSubview:view];
    return view;
}

static void AddConstraints(NSArray<NSLayoutConstraint *> *constraints) {
    for (NSLayoutConstraint *constraint in constraints) constraint.identifier = @"lore.layout";
    [NSLayoutConstraint activateConstraints:constraints];
}

static LoreSurfaceView *HeadingView(NSView *parent, NSString *identifier, NSString *title,
                                NSString *languageIdentifier, NSTextField *__strong *language) {
    LoreSurfaceView *heading = SurfaceView(parent, identifier, LoreGold);
    heading.cutCorners = YES;
    NSTextField *name = Label(title, 14, NSFontWeightBold, LoreColor(LoreGoldText));
    NSTextField *badge = Label(@"", 12, NSFontWeightBold, LoreColor(LoreGoldText));
    badge.identifier = languageIdentifier;
    name.maximumNumberOfLines = 1;
    badge.maximumNumberOfLines = 1;
    [heading addSubview:name];
    [heading addSubview:badge];
    AddConstraints(@[
        [name.leadingAnchor constraintEqualToAnchor:heading.leadingAnchor constant:12],
        [name.centerYAnchor constraintEqualToAnchor:heading.centerYAnchor],
        [name.trailingAnchor constraintLessThanOrEqualToAnchor:badge.leadingAnchor constant:-8],
        [badge.trailingAnchor constraintEqualToAnchor:heading.trailingAnchor constant:-12],
        [badge.centerYAnchor constraintEqualToAnchor:heading.centerYAnchor]
    ]);
    *language = badge;
    return heading;
}

static LoreActionButton *ButtonView(NSView *parent, NSString *identifier, NSString *title,
                               id target, SEL action, BOOL primary, BOOL plain) {
    LoreActionButton *button = [[LoreActionButton alloc] initWithFrame:NSZeroRect];
    button.identifier = identifier;
    [button setButtonType:NSButtonTypeMomentaryPushIn];
    button.bordered = NO;
    button.title = title;
    button.font = LoreLabelFont(14);
    button.contentTintColor = LoreColor(primary ? LoreHeaderText : LoreText);
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
    text.font = LoreBodyFont(18);
    text.textColor = LoreColor(LoreText);
    text.insertionPointColor = LoreAccentColor();
    text.selectedTextAttributes = @{
        NSBackgroundColorAttributeName: [LoreAccentColor() colorWithAlphaComponent:0.22],
        NSForegroundColorAttributeName: text.textColor
    };
    text.drawsBackground = NO;
    text.textContainerInset = NSMakeSize(0, 0);
    text.textContainer.lineFragmentPadding = 0;
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.lineSpacing = 5;
    paragraph.paragraphSpacing = 10;
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
                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskNonactivatingPanel |
                  NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    _panel.title = @"Lore";
    _panel.titleVisibility = NSWindowTitleHidden;
    _panel.titlebarAppearsTransparent = YES;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.opaque = NO;
    _panel.hasShadow = YES;
    _panel.movableByWindowBackground = YES;
    _panel.minSize = NSMakeSize(640, 420);
    _panel.tabbingMode = NSWindowTabbingModeDisallowed;
    [_panel setFrame:NSMakeRect(0, 0, 720, 500) display:NO];
    _panel.releasedWhenClosed = NO;
    _panel.hidesOnDeactivate = NO;
    _panel.floatingPanel = YES;
    _panel.becomesKeyOnlyIfNeeded = YES;
    _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorFullScreenAuxiliary;
    _panel.delegate = self;
    __weak TranslationPanel *weakSelf = self;
    _panel.onTranslateKey = ^{ [weakSelf performPrimaryAction:nil]; };
    _panel.onCopyKey = ^{ [weakSelf copyOutput:nil]; };
    _panel.onEscape = ^{
        TranslationPanel *owner = weakSelf;
        if (!owner) return;
        if ([owner isShowingSettings]) [owner showTranslation];
        else [owner close];
    };

    LoreSurfaceView *content = [[LoreSurfaceView alloc] initWithFrame:NSMakeRect(0, 0, 720, 500)];
    content.identifier = @"lore-panel";
    content.fillColor = LoreColor(LoreBackground);
    content.borderColor = LoreColor(LoreBorder);
    content.textured = YES;
    content.cornerRadius = 16;
    content.wantsLayer = YES;
    content.layer.cornerRadius = 16;
    content.layer.masksToBounds = YES;
    _panel.contentView = content;
    _translationContent = content;

    LoreSurfaceView *header = SurfaceView(content, @"header", LoreHeader);
    header.masthead = YES;
    header.draggable = YES;
    LoreSurfaceView *footer = SurfaceView(content, @"footer", LoreBackground);
    footer.textured = YES;
    LoreSurfaceView *footerLine = SurfaceView(content, @"footer-divider", LoreBorder);
    LoreSurfaceView *dividerTop = SurfaceView(content, @"pane-divider-top", LoreBorder);
    LoreSurfaceView *dividerBottom = SurfaceView(content, @"pane-divider-bottom", LoreBorder);

    LoreMascotView *mascot = [[LoreMascotView alloc] init];
    mascot.identifier = @"mascot";
    mascot.image = LoreMascotImage();
    mascot.translatesAutoresizingMaskIntoConstraints = NO;
    [mascot setAccessibilityElement:NO];
    [header addSubview:mascot];
    NSTextField *name = Label(@"Lore", LoreBrandLogoSize, NSFontWeightBold, LoreColor(LoreHeaderText));
    name.identifier = @"brand-name";
    name.font = LoreLogoFont(LoreBrandLogoSize);
    [header addSubview:name];
    LoreActionButton *settings = ButtonView(header, @"settings", @"", self, @selector(openSettings:), NO, YES);
    settings.image = LoreSymbol(@"gearshape", @"Settings", 20);
    settings.contentTintColor = LoreColor(LoreHeaderText);
    settings.imagePosition = NSImageOnly;
    settings.toolTip = @"Settings";
    [settings setAccessibilityLabel:@"Settings"];

    LoreSurfaceView *sourceHeading = HeadingView(content, @"source-heading", @"ORIGINAL",
                                              @"source-language", &_sourceLanguage);
    LoreSurfaceView *outputHeading = HeadingView(content, @"output-heading", @"TRANSLATION",
                                              @"output-language", &_outputLanguage);
    LoreSurfaceView *sourceRule = SurfaceView(content, @"source-rule", LoreBorder);
    LoreSurfaceView *outputRule = SurfaceView(content, @"output-rule", LoreBorder);

    _swap = ButtonView(content, @"swap", @"", self, @selector(swapText:), NO, NO);
    _swap.gold = YES;
    _swap.contentTintColor = LoreColor(LoreGoldText);
    _swap.image = LoreSymbol(@"arrow.right.arrow.left", @"", 17);
    _swap.imagePosition = NSImageOnly;
    _swap.toolTip = @"Swap text and translate back";
    [_swap setAccessibilityLabel:@"Swap text and translate back"];

    NSScrollView *sourceScroll = TextArea(content, &_source, YES, @"source", @"Source text",
                                         @"Type or paste text");
    NSScrollView *outputScroll = TextArea(content, &_output, NO, @"output", @"Translation", @"");
    _source.delegate = self;

    _instructions = Label(@"", 12, NSFontWeightRegular, LoreColor(LoreSecondaryText));
    _instructions.identifier = @"instructions";
    _instructions.maximumNumberOfLines = 2;
    _status = Label(@"", 12, NSFontWeightRegular, LoreColor(LoreSecondaryText));
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

    _translate = ButtonView(footer, @"translate", @"Translate  ⌘↵", self, @selector(performPrimaryAction:), YES, NO);
    _translate.toolTip = @"Translate or cancel (⌘Return)";
    _copy = ButtonView(footer, @"copy", @"Copy Translation", self, @selector(copyOutput:), NO, NO);
    _copy.toolTip = @"Copy Translation (⇧⌘C)";
    _copyIcon = LoreSymbol(@"doc.on.doc", @"", 13);
    _copiedIcon = LoreSymbol(@"checkmark", @"", 13);
    _copy.image = _copyIcon;
    _copy.imagePosition = NSImageLeft;
    _copy.imageHugsTitle = YES;
    _shortcutHint = Label(@"Type or paste text to translate", 12, NSFontWeightRegular, LoreColor(LoreSecondaryText));
    _shortcutHint.identifier = @"shortcut-hint";
    _shortcutHint.alignment = NSTextAlignmentCenter;
    _shortcutHint.maximumNumberOfLines = 2;
    [footer addSubview:_shortcutHint];
    // Only the two footer actions need their own composited press feedback.
    for (LoreActionButton *button in @[_translate, _copy]) {
        button.wantsLayer = YES;
        button.pressFeedback = YES;
    }

    AddConstraints(@[
        [header.topAnchor constraintEqualToAnchor:content.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:LoreHeaderHeight],
        [mascot.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:LoreBrandLeading],
        [mascot.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [mascot.widthAnchor constraintEqualToConstant:LoreBrandMarkSize],
        [mascot.heightAnchor constraintEqualToConstant:LoreBrandMarkSize],
        [name.leadingAnchor constraintEqualToAnchor:mascot.trailingAnchor constant:LoreBrandGap],
        [name.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [settings.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-24],
        [settings.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [settings.widthAnchor constraintEqualToConstant:36],
        [settings.heightAnchor constraintEqualToConstant:36],
        [name.trailingAnchor constraintLessThanOrEqualToAnchor:settings.leadingAnchor constant:-24],
        [sourceHeading.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:24],
        [sourceHeading.leadingAnchor constraintEqualToAnchor:sourceScroll.leadingAnchor],
        [sourceHeading.widthAnchor constraintEqualToConstant:222],
        [sourceHeading.heightAnchor constraintEqualToConstant:28],
        [outputHeading.topAnchor constraintEqualToAnchor:sourceHeading.topAnchor],
        [outputHeading.leadingAnchor constraintEqualToAnchor:outputScroll.leadingAnchor],
        [outputHeading.widthAnchor constraintEqualToAnchor:sourceHeading.widthAnchor],
        [outputHeading.heightAnchor constraintEqualToAnchor:sourceHeading.heightAnchor],
        [sourceRule.topAnchor constraintEqualToAnchor:sourceHeading.bottomAnchor constant:10],
        [sourceRule.leadingAnchor constraintEqualToAnchor:sourceScroll.leadingAnchor],
        [sourceRule.trailingAnchor constraintEqualToAnchor:sourceScroll.trailingAnchor],
        [sourceRule.heightAnchor constraintEqualToConstant:1.5],
        [outputRule.topAnchor constraintEqualToAnchor:sourceRule.topAnchor],
        [outputRule.leadingAnchor constraintEqualToAnchor:outputScroll.leadingAnchor],
        [outputRule.trailingAnchor constraintEqualToAnchor:outputScroll.trailingAnchor],
        [outputRule.heightAnchor constraintEqualToAnchor:sourceRule.heightAnchor],
        [_swap.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [_swap.centerYAnchor constraintEqualToAnchor:sourceScroll.centerYAnchor],
        [_swap.widthAnchor constraintEqualToConstant:36],
        [_swap.heightAnchor constraintEqualToConstant:36],
        [dividerTop.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [dividerTop.topAnchor constraintEqualToAnchor:sourceHeading.topAnchor],
        [dividerTop.bottomAnchor constraintEqualToAnchor:_swap.topAnchor constant:-8],
        [dividerTop.widthAnchor constraintEqualToConstant:1.5],
        [dividerBottom.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [dividerBottom.topAnchor constraintEqualToAnchor:_swap.bottomAnchor constant:8],
        [dividerBottom.bottomAnchor constraintEqualToAnchor:sourceScroll.bottomAnchor],
        [dividerBottom.widthAnchor constraintEqualToConstant:1.5],
        [sourceScroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [sourceScroll.trailingAnchor constraintEqualToAnchor:content.centerXAnchor constant:-24],
        [sourceScroll.topAnchor constraintEqualToAnchor:sourceRule.bottomAnchor constant:16],
        _messageSpacing,
        [outputScroll.leadingAnchor constraintEqualToAnchor:content.centerXAnchor constant:24],
        [outputScroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [outputScroll.topAnchor constraintEqualToAnchor:sourceScroll.topAnchor],
        [outputScroll.bottomAnchor constraintEqualToAnchor:sourceScroll.bottomAnchor],
        [messages.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [messages.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [messages.bottomAnchor constraintEqualToAnchor:footerLine.topAnchor constant:-16],
        [_instructions.widthAnchor constraintEqualToAnchor:messages.widthAnchor],
        [_status.widthAnchor constraintEqualToAnchor:messages.widthAnchor],
        [footerLine.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [footerLine.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [footerLine.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [footerLine.heightAnchor constraintEqualToConstant:1.5],
        [footer.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [footer.heightAnchor constraintEqualToConstant:72],
        [_translate.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:24],
        [_translate.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [_translate.widthAnchor constraintEqualToConstant:184],
        [_translate.heightAnchor constraintEqualToConstant:40],
        [_copy.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-24],
        [_copy.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [_copy.widthAnchor constraintEqualToConstant:176],
        [_copy.heightAnchor constraintEqualToAnchor:_translate.heightAnchor],
        [_shortcutHint.leadingAnchor constraintEqualToAnchor:_translate.trailingAnchor constant:12],
        [_shortcutHint.trailingAnchor constraintEqualToAnchor:_copy.leadingAnchor constant:-12],
        [_shortcutHint.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor]
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
    [self showTranslation];
    _inputDirection = lore::Direction::Automatic;
    _source.string = text;
    // A newly selected passage starts a new editing session, not an undo history
    // of every passage translated since the resident panel was first created.
    [_source.undoManager removeAllActions];
    [self setOutput:@"" direction:lore::Direction::Automatic];
    [self showWithoutChangingInput];
}

- (void)showWithoutChangingInput {
    [self showTranslation];
    [self positionNearPointer];
    [_panel orderFrontRegardless];
}

- (BOOL)isShowingSettings {
    return _settings && _panel.contentView == _settings.view;
}

- (void)showSettings:(SettingsViewController *)settings {
    BOOL entering = ![self isShowingSettings];
    if (entering) {
        _translationResponder = _panel.firstResponder;
        [_translate resetPressFeedback];
        [_copy resetPressFeedback];
        [_panel makeFirstResponder:nil];
        _settings = settings;
        __weak TranslationPanel *weakSelf = self;
        settings.onBack = ^{ [weakSelf showTranslation]; };
        NSView *view = settings.view;
        view.frame = _panel.contentView.bounds;
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        view.wantsLayer = YES;
        view.layer.cornerRadius = 16;
        view.layer.masksToBounds = YES;
        _panel.contentView = view;
        _panel.title = @"Lore Settings";
    }
    if (!_panel.visible) [self positionNearPointer];
    [settings refresh];
    [NSApp activateIgnoringOtherApps:YES];
    [_panel makeKeyAndOrderFront:nil];
    [settings setActive:_panel.keyWindow];
    if (entering) [settings focusInitialControl];
}

- (void)showTranslation {
    if (![self isShowingSettings]) return;
    [_settings setActive:NO];
    [_panel makeFirstResponder:nil];
    _translationContent.frame = _panel.contentView.bounds;
    _panel.contentView = _translationContent;
    _panel.title = @"Lore";
    if (![_panel makeFirstResponder:_translationResponder ?: _source]) {
        [_panel makeFirstResponder:_source];
    }
    _translationResponder = nil;
}

- (void)setShortcutAvailable:(BOOL)available {
    [self setShortcutInstructions:available ? @"" :
        @"Enable Double ⌘C in Settings to translate selected text."];
}

- (void)setShortcutInstructions:(NSString *)instructions {
    _instructions.stringValue = instructions;
    _instructions.hidden = instructions.length == 0;
    [self updateMessageSpacing];
}

- (void)updateMessageSpacing {
    _messageSpacing.constant = (_instructions.hidden && _status.hidden) ? 0 : -16;
}

- (void)showForManualInput {
    [self showTranslation];
    if (!_panel.isVisible) [self positionNearPointer];
    [NSApp activateIgnoringOtherApps:YES];
    [_panel makeKeyAndOrderFront:nil];
    [_panel makeFirstResponder:_source];
}

- (void)setAvailable:(BOOL)available busy:(BOOL)busy status:(NSString *)status kind:(LoreStatusKind)kind {
    _available = available;
    _busy = busy;
    _status.stringValue = status;
    _status.textColor = LoreColor(kind == LoreStatusError ? LoreError :
                                 kind == LoreStatusWarning ? LoreWarning : LoreSecondaryText);
    _status.hidden = status.length == 0;
    [self updateMessageSpacing];
    [self updateButtons];
}

- (void)setOutput:(NSString *)output direction:(lore::Direction)direction {
    if (output.length == 0 && direction == lore::Direction::Automatic) _sourceEditedSinceRequest = NO;
    _outputDirection = direction;
    if (![_output.string isEqualToString:output]) {
        NSScrollView *scroll = _output.enclosingScrollView;
        NSClipView *clip = scroll.contentView;
        NSPoint readingPosition = clip.bounds.origin;
        NSUInteger previousLength = _output.string.length;
        // Follow a new result or a reader already within one line of the end.
        // Read geometry on this output event; do not retain another text buffer.
        BOOL followEnd = previousLength == 0 ||
            NSMaxY(scroll.documentVisibleRect) >= NSMaxY(_output.bounds) - 24;
        [self resetCopyFeedback];
        if (previousLength && output.length > previousLength && [output hasPrefix:_output.string]) {
            // Streaming growth only edits the new tail. Keep earlier glyphs and
            // the reader's position instead of replacing the entire text store.
            [_output.textStorage replaceCharactersInRange:NSMakeRange(previousLength, 0)
                withString:[output substringFromIndex:previousLength]];
        } else {
            _output.string = output;
        }
        if (output.length && followEnd) {
            // Resolve the end before scrolling: deferred layout can otherwise
            // grow the document after AppKit has chosen a stale scroll offset.
            [_output.layoutManager ensureLayoutForCharacterRange:NSMakeRange(output.length - 1, 1)];
            [_output sizeToFit];
            [_output scrollRangeToVisible:NSMakeRange(output.length, 0)];
        } else {
            [clip scrollToPoint:output.length ? readingPosition : NSZeroPoint];
            [scroll reflectScrolledClipView:clip];
        }
    }
    [self updateButtons];
}

- (void)updateButtons {
    [self updateLanguageLabels];
    BOOL hasInput = [_source.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
    BOOL hasOutput = _output.string.length > 0;
    _shortcutHint.hidden = hasInput || hasOutput || _busy;
    _translate.enabled = _busy || (_available && hasInput);
    _translate.contentTintColor = _translate.enabled ? LoreColor(LoreHeaderText) : nil;
    _translate.title = _busy ? @"Cancel  ⌘↵" : (hasOutput ? @"Retranslate  ⌘↵" : @"Translate  ⌘↵");
    _copy.enabled = hasOutput;
    _copy.contentTintColor = _copy.enabled ? LoreColor(LoreText) : nil;
    _swap.enabled = _available && !_busy && hasOutput && _outputDirection != lore::Direction::Automatic;
}

- (void)updateLanguageLabels {
    lore::Direction sourceDirection = _inputDirection;
    if (sourceDirection == lore::Direction::Automatic && !_sourceEditedSinceRequest) {
        sourceDirection = _outputDirection;
    }
    _sourceLanguage.stringValue = sourceDirection == lore::Direction::EnglishToJapanese ? @"EN" :
        sourceDirection == lore::Direction::JapaneseToEnglish ? @"JA" : @"AUTO";
    _outputLanguage.stringValue = _outputDirection == lore::Direction::EnglishToJapanese ? @"JA" :
        _outputDirection == lore::Direction::JapaneseToEnglish ? @"EN" : @"—";
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
    if ([self isShowingSettings]) return;
    if (_busy) { if (self.onCancel) self.onCancel(); }
    else [self translate:sender];
}

- (void)openSettings:(id)sender { if (self.onSettings) self.onSettings(); }

- (void)copyOutput:(id)sender {
    if ([self isShowingSettings]) return;
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
    _sourceEditedSinceRequest = YES;
    _inputDirection = lore::Direction::Automatic;
    _source.needsDisplay = YES;
    [self updateButtons];
}
- (void)windowWillClose:(NSNotification *)notification {
    [self showTranslation];
    [_translate resetPressFeedback];
    [_copy resetPressFeedback];
    [self resetCopyFeedback];
    if (self.onClose) self.onClose();
}
- (void)windowDidBecomeKey:(NSNotification *)notification {
    if ([self isShowingSettings]) [_settings setActive:YES];
}
- (void)windowDidResignKey:(NSNotification *)notification {
    [_settings setActive:NO];
}
- (void)close { [_panel close]; }
@end
