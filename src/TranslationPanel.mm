#import "TranslationPanel.h"
#import "SettingsViewController.h"
#import "OnboardingViewController.h"
#import "BawanPanelPage.h"
#import "BawanAppearance.h"
#import "BawanChrome.h"
#import "BawanMascotView.h"
#import <QuartzCore/CALayer.h>
#import <QuartzCore/CAAnimation.h>
#import <QuartzCore/CAMediaTimingFunction.h>
#import <QuartzCore/CATransaction.h>

#include <algorithm>

@interface BawanPanel : NSPanel
@property(nonatomic, copy) void (^onTranslateKey)(void);
@property(nonatomic, copy) void (^onCopyKey)(void);
@property(nonatomic, copy) void (^onEscape)(void);
@property(nonatomic, weak) NSView *editingContent;
@end

@implementation BawanPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
- (NSUndoManager *)undoManager {
    return self.contentView == self.editingContent ? [super undoManager] : nil;
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

@interface BawanTextView : NSTextView
@property(nonatomic, copy) NSString *placeholder;
@end

@implementation BawanTextView
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (self.string.length == 0) {
        [self.placeholder drawInRect:NSInsetRect(self.bounds, 1, 1) withAttributes:
            @{NSFontAttributeName:self.font, NSForegroundColorAttributeName:BawanColor(BawanSecondaryText)}];
    }
}
@end

@interface TranslationPanel () <NSWindowDelegate, NSTextViewDelegate> {
    BawanPanel *_panel;
    NSView *_translationContent;
    BawanMascotView *_mascot;
    NSViewController<BawanPanelPage> *_page;
    BawanPanelPageKind _currentPage;
    __weak NSResponder *_translationResponder;
    BawanTextView *_source;
    BawanTextView *_output;
    BawanActionButton *_swap;
    bawan::Direction _inputDirection;
    bawan::Direction _outputDirection;
    NSTextField *_status;
    NSTextField *_instructions;
    NSTextField *_shortcutHint;
    NSLayoutConstraint *_messageSpacing;
    BawanActionButton *_translate;
    BawanActionButton *_copy;
    NSImage *_copyIcon;
    NSImage *_copiedIcon;
    BOOL _available;
    BOOL _busy;
}
@end

@implementation TranslationPanel

static void AddConstraints(NSArray<NSLayoutConstraint *> *constraints) {
    for (NSLayoutConstraint *constraint in constraints) constraint.identifier = @"bawan.layout";
    [NSLayoutConstraint activateConstraints:constraints];
}

static NSScrollView *TextArea(NSView *parent, BawanTextView *__strong *textView, BOOL editable,
                               NSString *identifier, NSString *label, NSString *placeholder) {
    // Start the clip view and document at the same width. Otherwise the first
    // autoresize adds the initial document width and silently clips long lines.
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 280, 140)];
    scroll.borderType = NSNoBorder;
    BawanConfigurePaperScrollView(scroll);
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    BawanTextView *text = [[BawanTextView alloc] initWithFrame:NSMakeRect(0, 0, 280, 140)];
    text.identifier = identifier;
    text.placeholder = placeholder;
    text.editable = editable;
    text.selectable = YES;
    text.richText = NO;
    text.font = BawanBodyFont(18);
    text.textColor = BawanColor(BawanText);
    text.insertionPointColor = BawanAccentColor();
    text.selectedTextAttributes = @{
        NSBackgroundColorAttributeName: [BawanAccentColor() colorWithAlphaComponent:0.22],
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
    _panel = [[BawanPanel alloc] initWithContentRect:NSMakeRect(0, 0, 720, 500)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskNonactivatingPanel |
                  NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    _panel.title = @"Bawan";
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
    _panel.floatingPanel = NO;
    _panel.level = NSNormalWindowLevel;
    _panel.becomesKeyOnlyIfNeeded = YES;
    _panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace |
                                NSWindowCollectionBehaviorFullScreenAuxiliary;
    _panel.delegate = self;
    __weak TranslationPanel *weakSelf = self;
    _panel.onTranslateKey = ^{ [weakSelf performPrimaryAction:nil]; };
    _panel.onCopyKey = ^{ [weakSelf copyOutput:nil]; };
    _panel.onEscape = ^{
        TranslationPanel *owner = weakSelf;
        if (!owner) return;
        if ([owner isShowingPage]) { if (owner->_page.onBack) owner->_page.onBack(); }
        else [owner close];
    };

    BawanSurfaceView *content = BawanMakeWindowSurface(@"bawan-panel", NSMakeRect(0, 0, 720, 500));
    _panel.contentView = content;
    _panel.editingContent = content;
    _translationContent = content;

    BawanChromeHeader chrome = BawanAddHeader(content, @"header", @"mascot");
    BawanSurfaceView *header = chrome.header;
    _mascot = chrome.mascot;
    BawanActionButton *settings = BawanAddHeaderButton(header, @"settings", @"gearshape", @"Settings",
        self, @selector(openSettings:));
    settings.toolTip = @"Settings";
    BawanChromeFooter footerChrome = BawanAddFooter(content, @"footer");
    BawanSurfaceView *footer = footerChrome.footer;
    BawanSurfaceView *footerLine = footerChrome.divider;
    BawanSurfaceView *dividerTop = BawanAddSurface(content, @"pane-divider-top", BawanBorder);
    BawanSurfaceView *dividerBottom = BawanAddSurface(content, @"pane-divider-bottom", BawanBorder);

    _swap = BawanAddActionButton(content, @"swap", @"", self, @selector(swapText:), BawanActionButtonStyleGold);
    _swap.contentTintColor = BawanColor(BawanGoldText);
    _swap.image = BawanSymbol(@"arrow.right.arrow.left", @"", 17);
    _swap.imagePosition = NSImageOnly;
    _swap.toolTip = @"Swap text and translate back";
    [_swap setAccessibilityLabel:@"Swap text and translate back"];

    NSScrollView *sourceScroll = TextArea(content, &_source, YES, @"source", @"Source text",
                                         @"Type or paste text");
    NSScrollView *outputScroll = TextArea(content, &_output, NO, @"output", @"Translation", @"");
    _source.delegate = self;

    _instructions = BawanLabel(@"", 12, NSFontWeightRegular, BawanColor(BawanSecondaryText));
    _instructions.identifier = @"instructions";
    _instructions.maximumNumberOfLines = 2;
    _status = BawanLabel(@"", 12, NSFontWeightRegular, BawanColor(BawanSecondaryText));
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

    _translate = BawanAddFooterPrimary(footer, @"translate", @"Translate  ⌘↵", self, @selector(performPrimaryAction:));
    _translate.toolTip = @"Translate or cancel (⌘Return)";
    _copy = BawanAddFooterSecondary(footer, @"copy", @"Copy Translation", self, @selector(copyOutput:));
    _copy.toolTip = @"Copy Translation (⇧⌘C)";
    _copyIcon = BawanSymbol(@"doc.on.doc", @"", 13);
    _copiedIcon = BawanSymbol(@"checkmark", @"", 13);
    _copy.image = _copyIcon;
    _copy.imagePosition = NSImageLeft;
    _copy.imageHugsTitle = YES;
    _shortcutHint = BawanAddFooterHint(footer, @"shortcut-hint", @"Type or paste text to translate", _translate, _copy);

    AddConstraints(@[
        [_swap.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [_swap.centerYAnchor constraintEqualToAnchor:sourceScroll.centerYAnchor],
        [_swap.widthAnchor constraintEqualToConstant:36],
        [_swap.heightAnchor constraintEqualToConstant:36],
        [dividerTop.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [dividerTop.topAnchor constraintEqualToAnchor:sourceScroll.topAnchor],
        [dividerTop.bottomAnchor constraintEqualToAnchor:_swap.topAnchor constant:-8],
        [dividerTop.widthAnchor constraintEqualToConstant:1.5],
        [dividerBottom.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [dividerBottom.topAnchor constraintEqualToAnchor:_swap.bottomAnchor constant:8],
        [dividerBottom.bottomAnchor constraintEqualToAnchor:sourceScroll.bottomAnchor],
        [dividerBottom.widthAnchor constraintEqualToConstant:1.5],
        [sourceScroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [sourceScroll.trailingAnchor constraintEqualToAnchor:content.centerXAnchor constant:-24],
        [sourceScroll.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:24],
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
    [self setSelection:text];
    [self showWithoutChangingInput];
}

- (void)setSelection:(NSString *)text {
    _inputDirection = bawan::Direction::Automatic;
    _source.string = text;
    [_source.undoManager removeAllActions];
    [self setOutput:@"" direction:bawan::Direction::Automatic];
}

- (void)showWithoutChangingInput {
    [self showTranslation];
    [self positionNearPointer];
    // Raise once within the normal window level, without taking the source app's focus.
    [_panel orderFrontRegardless];
}

- (BOOL)isShowingPage {
    return _currentPage != BawanPanelPageTranslation;
}

- (NSWindow *)window { return _panel; }
- (BawanPanelPageKind)currentPage { return _currentPage; }

- (void)showSettings:(SettingsViewController *)settings {
    __weak TranslationPanel *weakSelf = self;
    [self showPage:settings kind:BawanPanelPageSettings title:@"Bawan Settings" onBack:^{ [weakSelf showTranslation]; }];
}

- (void)showOnboarding:(OnboardingViewController *)onboarding onBack:(void (^)(void))onBack {
    [self showPage:onboarding kind:BawanPanelPageOnboarding title:@"Bawan Setup" onBack:onBack];
}

- (void)showPage:(NSViewController<BawanPanelPage> *)page kind:(BawanPanelPageKind)kind
           title:(NSString *)title onBack:(void (^)(void))onBack {
    page.onBack = onBack;
    BOOL showingPage = [self isShowingPage];
    BOOL entering = !showingPage || _page != page;
    if (entering) {
        if (showingPage) {
            if (_panel.attachedSheet) [_panel endSheet:_panel.attachedSheet returnCode:NSModalResponseCancel];
            [_page setActive:NO];
            if ([_page respondsToSelector:@selector(willLeavePanelPage)]) [_page willLeavePanelPage];
        } else {
            _translationResponder = _panel.firstResponder;
            [_mascot resetHoverAnimation];
            [_translate resetPressFeedback];
            [_copy resetPressFeedback];
        }
        [_panel makeFirstResponder:nil];
        _page = page;
        _currentPage = kind;
        NSView *view = page.view;
        view.frame = _panel.contentView.bounds;
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _panel.contentView = view;
        _panel.title = title;
    }
    if (!_panel.visible) [self positionNearPointer];
    [page refresh];
    [NSApp activateIgnoringOtherApps:YES];
    [_panel makeKeyAndOrderFront:nil];
    [page setActive:_panel.keyWindow];
    if (entering) [page focusInitialControl];
}

- (void)showTranslation {
    if (![self isShowingPage]) return;
    if (_panel.attachedSheet) [_panel endSheet:_panel.attachedSheet returnCode:NSModalResponseCancel];
    [_page setActive:NO];
    if ([_page respondsToSelector:@selector(willLeavePanelPage)]) [_page willLeavePanelPage];
    [_panel makeFirstResponder:nil];
    _translationContent.frame = _panel.contentView.bounds;
    _panel.contentView = _translationContent;
    _currentPage = BawanPanelPageTranslation;
    _panel.title = @"Bawan";
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

- (void)setAvailable:(BOOL)available busy:(BOOL)busy {
    _available = available;
    _busy = busy;
    [self updateButtons];
}

- (void)setAvailable:(BOOL)available busy:(BOOL)busy status:(NSString *)status kind:(BawanStatusKind)kind {
    _status.stringValue = status;
    _status.textColor = BawanColor(kind == BawanStatusError ? BawanError :
                                 kind == BawanStatusWarning ? BawanWarning : BawanSecondaryText);
    _status.hidden = status.length == 0;
    [self updateMessageSpacing];
    [self setAvailable:available busy:busy];
}

- (void)setOutput:(NSString *)output direction:(bawan::Direction)direction {
    _outputDirection = direction;
    if (![_output.string isEqualToString:output]) {
        NSScrollView *scroll = _output.enclosingScrollView;
        NSClipView *clip = scroll.contentView;
        NSRect readingRect = scroll.documentVisibleRect;
        NSUInteger previousLength = _output.string.length;
        BOOL followEnd = previousLength == 0 ||
            NSMaxY(readingRect) >= NSMaxY(_output.bounds) - 24;
        [self resetCopyFeedback];
        if (previousLength && output.length > previousLength && [output hasPrefix:_output.string]) {
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
            // Document coordinates stay meaningful when the clip view adjusts
            // its origin as the text document grows.
            [_output scrollRectToVisible:output.length ? readingRect : NSMakeRect(0, 0, 1, 1)];
            [scroll reflectScrolledClipView:clip];
        }
    }
    [self updateButtons];
}

- (void)updateButtons {
    BOOL hasInput = [_source.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
    BOOL hasOutput = _output.string.length > 0;
    _shortcutHint.hidden = hasInput || hasOutput || _busy;
    _translate.enabled = _busy || (_available && hasInput);
    _translate.contentTintColor = _translate.enabled ? BawanColor(BawanHeaderText) : nil;
    _translate.title = _busy ? @"Cancel  ⌘↵" : (hasOutput ? @"Retranslate  ⌘↵" : @"Translate  ⌘↵");
    _copy.enabled = hasOutput;
    _copy.contentTintColor = _copy.enabled ? BawanColor(BawanText) : nil;
    _swap.enabled = _available && !_busy && hasOutput && _outputDirection != bawan::Direction::Automatic;
}

- (void)translate:(id)sender {
    BOOL hasInput = [_source.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
    if (_available && hasInput && self.onTranslate) self.onTranslate(_source.string, _inputDirection);
}

- (void)swapText:(id)sender {
    if (!_swap.enabled) return;
    _inputDirection = _outputDirection == bawan::Direction::EnglishToJapanese ?
        bawan::Direction::JapaneseToEnglish : bawan::Direction::EnglishToJapanese;
    _source.string = _output.string;
    [_source.undoManager removeAllActions];
    [_source scrollRangeToVisible:NSMakeRange(0, 0)];
    [self setOutput:@"" direction:bawan::Direction::Automatic];
    [self translate:nil];
}

- (void)performPrimaryAction:(id)sender {
    if ([self isShowingPage]) {
        [_page performPrimaryAction];
        return;
    }
    if (_busy) { if (self.onCancel) self.onCancel(); }
    else [self translate:sender];
}

- (void)openSettings:(id)sender { if (self.onSettings) self.onSettings(); }

- (void)copyOutput:(id)sender {
    if ([self isShowingPage]) return;
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
    _copy.title = @"Copy Translation";
    _copy.image = _copyIcon;
}

- (void)textDidChange:(NSNotification *)notification {
    if (notification.object != _source) return;
    if (_busy && self.onCancel) self.onCancel();
    _inputDirection = bawan::Direction::Automatic;
    _source.needsDisplay = YES;
    [self setOutput:@"" direction:bawan::Direction::Automatic];
}
- (void)windowWillClose:(NSNotification *)notification {
    [self showTranslation];
    [_mascot resetHoverAnimation];
    [_translate resetPressFeedback];
    [_copy resetPressFeedback];
    [self resetCopyFeedback];
    if (self.onClose) self.onClose();
}
- (void)windowDidBecomeKey:(NSNotification *)notification {
    if ([self isShowingPage]) [_page setActive:YES];
}
- (void)windowDidResignKey:(NSNotification *)notification {
    if ([self isShowingPage]) [_page setActive:NO];
}
- (void)close { [_panel close]; }
@end
