#import "TranslationPanel.h"
#import <QuartzCore/CALayer.h>

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
        NSMutableArray<NSColor *> *palette = [NSMutableArray array];
        for (NSUInteger i = 0; i < sizeof(light) / sizeof(light[0]); ++i) {
            NSColor *lightColor = RGB(light[i]);
            NSColor *darkColor = RGB(dark[i]);
            [palette addObject:[NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
                NSString *match = [appearance bestMatchFromAppearancesWithNames:
                    @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
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

@interface LoreButton : NSButton
@property(nonatomic) BOOL primary;
@property(nonatomic) BOOL plain;
@end

@implementation LoreButton
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

@interface LoreDirectionCell : NSPopUpButtonCell {
    NSAttributedString *_automaticTitle;
    NSImage *_chevron;
}
@end

@implementation LoreDirectionCell
- (instancetype)initTextCell:(NSString *)string pullsDown:(BOOL)pullDown {
    self = [super initTextCell:string pullsDown:pullDown];
    if (self) {
        NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:@"Auto  |  "
            attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
                         NSForegroundColorAttributeName:Color(SecondaryText)}];
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:@"EN ↔ JP"
            attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
                         NSForegroundColorAttributeName:Color(Text)}]];
        _automaticTitle = [title copy];
        _chevron = [Symbol(@"chevron.down", @"", 10) imageWithSymbolConfiguration:
            [NSImageSymbolConfiguration configurationWithHierarchicalColor:Color(SecondaryText)]];
    }
    return self;
}
- (void)drawBezelWithFrame:(NSRect)frame inView:(NSView *)view {
    DrawButton(frame, NO, self.highlighted, self.enabled);
}
- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)view {
    NSRect titleRect = NSMakeRect(frame.origin.x + 14, NSMidY(frame) - 8,
                                  frame.size.width - 42, 18);
    if (self.indexOfSelectedItem == 0) [_automaticTitle drawInRect:titleRect];
    else [self.selectedItem.title drawInRect:titleRect withAttributes:
        @{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
          NSForegroundColorAttributeName:Color(Text)}];
    [_chevron drawInRect:NSMakeRect(NSMaxX(frame) - 26, NSMidY(frame) - 5, 12, 10)
               fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
         respectFlipped:YES hints:nil];
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
    NSPopUpButton *_direction;
    NSTextField *_status;
    NSTextField *_instructions;
    NSLayoutConstraint *_instructionsHeight;
    LoreButton *_translate;
    LoreButton *_copy;
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
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.borderType = NSNoBorder;
    scroll.hasVerticalScroller = YES;
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
    text.font = [NSFont systemFontOfSize:editable ? 16 : 17];
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
    LoreSurface *divider = SurfaceView(content, @"pane-divider", Border);

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

    _direction = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _direction.cell = [[LoreDirectionCell alloc] initTextCell:@"" pullsDown:NO];
    [_direction addItemsWithTitles:@[@"Auto (EN ↔ JP)", @"English → Japanese", @"Japanese → English"]];
    _direction.identifier = @"direction";
    _direction.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    _direction.translatesAutoresizingMaskIntoConstraints = NO;
    [_direction setAccessibilityLabel:@"Translation direction"];
    [content addSubview:_direction];

    NSTextField *sourceLabel = Label(@"Source", 12, NSFontWeightMedium, Color(SecondaryText));
    NSTextField *outputLabel = Label(@"Translation", 12, NSFontWeightMedium, Color(SecondaryText));
    [content addSubview:sourceLabel];
    [content addSubview:outputLabel];
    NSScrollView *sourceScroll = TextArea(content, &_source, YES, @"source", @"Source text",
                                         @"Type or paste text to translate.");
    NSScrollView *outputScroll = TextArea(content, &_output, NO, @"output", @"Translation",
                                         @"Your translation will appear here.");
    _source.delegate = self;

    _instructions = Label(@"", 11, NSFontWeightRegular, Color(SecondaryText));
    _instructions.identifier = @"instructions";
    _instructions.maximumNumberOfLines = 2;
    [content addSubview:_instructions];
    _instructionsHeight = [_instructions.heightAnchor constraintEqualToConstant:0];
    _status = Label(@"Preparing model…", 11, NSFontWeightRegular, Color(SecondaryText));
    _status.identifier = @"status";
    _status.maximumNumberOfLines = 3;
    [_status setAccessibilityLabel:@"Translation status"];
    [content addSubview:_status];

    NSImageView *device = [[NSImageView alloc] initWithFrame:NSZeroRect];
    device.image = Symbol(@"laptopcomputer", @"", 14);
    device.contentTintColor = Color(SecondaryText);
    device.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:device];
    NSTextField *local = Label(@"On-device translation", 11, NSFontWeightMedium, Color(SecondaryText));
    [footer addSubview:local];
    _translate = ButtonView(footer, @"translate", @"Translate  ⌘↵", self, @selector(performPrimaryAction:), NO, NO);
    _translate.toolTip = @"Translate (⌘Return); cancel while translating";
    _copy = ButtonView(footer, @"copy", @"Copy Translation", self, @selector(copyOutput:), YES, NO);
    _copy.image = Symbol(@"doc.on.doc", @"", 13);
    _copy.imagePosition = NSImageLeft;

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
        [mark.widthAnchor constraintEqualToConstant:22],
        [mark.heightAnchor constraintEqualToConstant:22],
        [name.leadingAnchor constraintEqualToAnchor:mark.trailingAnchor constant:10],
        [name.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [dismiss.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [dismiss.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [dismiss.widthAnchor constraintEqualToConstant:46],
        [dismiss.heightAnchor constraintEqualToConstant:32],
        [settings.trailingAnchor constraintEqualToAnchor:dismiss.leadingAnchor constant:-12],
        [settings.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [settings.widthAnchor constraintEqualToConstant:32],
        [settings.heightAnchor constraintEqualToConstant:32],
        [_direction.topAnchor constraintEqualToAnchor:headerLine.bottomAnchor constant:15],
        [_direction.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [_direction.widthAnchor constraintEqualToConstant:232],
        [_direction.heightAnchor constraintEqualToConstant:34],
        [divider.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [divider.topAnchor constraintEqualToAnchor:_direction.bottomAnchor constant:18],
        [divider.bottomAnchor constraintEqualToAnchor:sourceScroll.bottomAnchor],
        [divider.widthAnchor constraintEqualToConstant:1],
        [sourceLabel.topAnchor constraintEqualToAnchor:_direction.bottomAnchor constant:24],
        [sourceLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [sourceLabel.heightAnchor constraintEqualToConstant:18],
        [outputLabel.topAnchor constraintEqualToAnchor:sourceLabel.topAnchor],
        [outputLabel.leadingAnchor constraintEqualToAnchor:divider.trailingAnchor constant:24],
        [outputLabel.heightAnchor constraintEqualToAnchor:sourceLabel.heightAnchor],
        [sourceScroll.leadingAnchor constraintEqualToAnchor:sourceLabel.leadingAnchor],
        [sourceScroll.trailingAnchor constraintEqualToAnchor:divider.leadingAnchor constant:-24],
        [sourceScroll.topAnchor constraintEqualToAnchor:sourceLabel.bottomAnchor constant:14],
        [sourceScroll.bottomAnchor constraintEqualToAnchor:_instructions.topAnchor constant:-12],
        [outputScroll.leadingAnchor constraintEqualToAnchor:outputLabel.leadingAnchor],
        [outputScroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [outputScroll.topAnchor constraintEqualToAnchor:sourceScroll.topAnchor],
        [outputScroll.bottomAnchor constraintEqualToAnchor:sourceScroll.bottomAnchor],
        [_instructions.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [_instructions.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [_instructions.bottomAnchor constraintEqualToAnchor:_status.topAnchor constant:-6],
        _instructionsHeight,
        [_status.leadingAnchor constraintEqualToAnchor:_instructions.leadingAnchor],
        [_status.trailingAnchor constraintEqualToAnchor:_instructions.trailingAnchor],
        [_status.bottomAnchor constraintEqualToAnchor:footerLine.topAnchor constant:-6],
        [_status.heightAnchor constraintEqualToConstant:42],
        [footerLine.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [footerLine.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [footerLine.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [footerLine.heightAnchor constraintEqualToConstant:1],
        [footer.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [footer.heightAnchor constraintEqualToConstant:64],
        [device.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:24],
        [device.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [device.widthAnchor constraintEqualToConstant:17],
        [device.heightAnchor constraintEqualToConstant:17],
        [local.leadingAnchor constraintEqualToAnchor:device.trailingAnchor constant:8],
        [local.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [local.trailingAnchor constraintLessThanOrEqualToAnchor:_translate.leadingAnchor constant:-12],
        [_copy.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-24],
        [_copy.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [_copy.widthAnchor constraintEqualToConstant:168],
        [_copy.heightAnchor constraintEqualToConstant:34],
        [_translate.trailingAnchor constraintEqualToAnchor:_copy.leadingAnchor constant:-12],
        [_translate.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [_translate.widthAnchor constraintEqualToConstant:140],
        [_translate.heightAnchor constraintEqualToConstant:34]
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
    _source.string = text;
    // A newly selected passage starts a new editing session, not an undo history
    // of every passage translated since the resident panel was first created.
    [_source.undoManager removeAllActions];
    [self setOutput:@""];
    [self showWithoutChangingInput];
}

- (void)showWithoutChangingInput {
    [self positionNearPointer];
    [_panel orderFrontRegardless];
}

- (void)setShortcutAvailable:(BOOL)available {
    _instructions.stringValue = available ? @"" :
        @"Enable Double ⌘C in Settings to translate selected text. Manual input works with ⌘Return.";
    _instructions.hidden = available;
    _instructionsHeight.constant = available ? 0 : 32;
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
    [self updateButtons];
}

- (void)setOutput:(NSString *)output {
    _output.string = output;
    [_output scrollRangeToVisible:NSMakeRange(output.length, 0)];
    [self updateButtons];
}

- (NSInteger)directionIndex { return _direction.indexOfSelectedItem; }

- (void)updateButtons {
    BOOL hasInput = [_source.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
    BOOL hasOutput = _output.string.length > 0;
    _translate.enabled = _busy || (_available && hasInput);
    _translate.title = _busy ? @"Cancel" : (hasOutput ? @"Retranslate  ⌘↵" : @"Translate  ⌘↵");
    _copy.enabled = hasOutput;
}

- (void)translate:(id)sender {
    BOOL hasInput = [_source.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
    if (_available && hasInput && self.onTranslate) self.onTranslate(_source.string, _direction.indexOfSelectedItem);
}

- (void)performPrimaryAction:(id)sender {
    if (_busy) { if (self.onCancel) self.onCancel(); }
    else [self translate:sender];
}

- (void)openSettings:(id)sender { if (self.onSettings) self.onSettings(); }
- (void)dismiss:(id)sender { [_panel close]; }

- (void)copyOutput:(id)sender {
    if (_output.string.length == 0) return;
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard writeObjects:@[_output.string]];
}

- (void)textDidChange:(NSNotification *)notification {
    _source.needsDisplay = YES;
    [self updateButtons];
}
- (void)windowWillClose:(NSNotification *)notification { if (self.onClose) self.onClose(); }
- (void)close { [_panel close]; }
@end
