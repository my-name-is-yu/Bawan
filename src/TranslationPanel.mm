#import "TranslationPanel.h"

#include <algorithm>

@interface LorePanel : NSPanel
@end

@implementation LorePanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
- (void)cancelOperation:(id)sender { [self close]; }
@end

@interface TranslationPanel () <NSWindowDelegate, NSTextViewDelegate> {
    LorePanel *_panel;
    NSTextView *_source;
    NSTextView *_output;
    NSPopUpButton *_direction;
    NSTextField *_status;
    NSTextField *_instructions;
    NSButton *_translate;
    NSButton *_cancel;
    NSButton *_copy;
    BOOL _available;
    BOOL _busy;
}
@end

@implementation TranslationPanel

static NSTextField *Label(NSString *text) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    return label;
}

static NSScrollView *TextArea(NSTextView *__strong *textView, BOOL editable, NSString *label) {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.borderType = NSBezelBorder;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextView *text = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 480, 140)];
    text.editable = editable;
    text.selectable = YES;
    text.richText = NO;
    text.font = [NSFont systemFontOfSize:14];
    text.textColor = NSColor.textColor;
    text.backgroundColor = NSColor.textBackgroundColor;
    text.textContainerInset = NSMakeSize(10, 10);
    text.verticallyResizable = YES;
    text.horizontallyResizable = NO;
    text.minSize = NSMakeSize(0, 0);
    text.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    text.autoresizingMask = NSViewWidthSizable;
    text.textContainer.containerSize = NSMakeSize(480, CGFLOAT_MAX);
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
    *textView = text;
    return scroll;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _panel = [[LorePanel alloc] initWithContentRect:NSMakeRect(0, 0, 560, 620)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                  NSWindowStyleMaskResizable | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    _panel.title = @"Lore";
    _panel.minSize = NSMakeSize(440, 580);
    _panel.releasedWhenClosed = NO;
    _panel.hidesOnDeactivate = NO;
    _panel.floatingPanel = YES;
    _panel.becomesKeyOnlyIfNeeded = YES;
    _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorFullScreenAuxiliary;
    _panel.delegate = self;

    NSView *content = _panel.contentView;
    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-18],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16]
    ]];

    _instructions = [NSTextField wrappingLabelWithString:@""];
    _instructions.font = [NSFont systemFontOfSize:11];
    _instructions.textColor = NSColor.secondaryLabelColor;
    _instructions.maximumNumberOfLines = 3;
    [stack addArrangedSubview:_instructions];
    [self setShortcutAvailable:NO];
    NSTextField *sourceLabel = Label(@"原文");
    [stack addArrangedSubview:sourceLabel];
    NSScrollView *sourceScroll = TextArea(&_source, YES, @"翻訳する原文");
    _source.delegate = self;
    [stack addArrangedSubview:sourceScroll];

    _direction = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_direction addItemsWithTitles:@[@"自動（英語 ↔ 日本語）", @"英語 → 日本語", @"日本語 → 英語"]];
    [_direction setAccessibilityLabel:@"翻訳方向"];
    [stack addArrangedSubview:_direction];
    [stack addArrangedSubview:Label(@"訳文")];
    NSScrollView *outputScroll = TextArea(&_output, NO, @"翻訳結果");
    [stack addArrangedSubview:outputScroll];

    _status = [NSTextField wrappingLabelWithString:@"モデルを準備しています…"];
    _status.font = [NSFont systemFontOfSize:12];
    _status.textColor = NSColor.secondaryLabelColor;
    _status.maximumNumberOfLines = 3;
    [_status setAccessibilityLabel:@"翻訳の状態"];
    [stack addArrangedSubview:_status];

    _translate = [NSButton buttonWithTitle:@"翻訳" target:self action:@selector(translate:)];
    _translate.keyEquivalent = @"\r";
    _translate.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    _cancel = [NSButton buttonWithTitle:@"中止" target:self action:@selector(cancel:)];
    _copy = [NSButton buttonWithTitle:@"訳文をコピー" target:self action:@selector(copyOutput:)];
    NSButton *settings = [NSButton buttonWithTitle:@"設定…" target:self action:@selector(openSettings:)];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[_translate, _cancel, _copy, settings]];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.spacing = 8;
    [stack addArrangedSubview:buttons];
    [NSLayoutConstraint activateConstraints:@[
        [sourceScroll.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [outputScroll.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [_instructions.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [_status.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [sourceScroll.heightAnchor constraintGreaterThanOrEqualToConstant:100],
        [outputScroll.heightAnchor constraintGreaterThanOrEqualToConstant:120],
        [outputScroll.heightAnchor constraintEqualToAnchor:sourceScroll.heightAnchor multiplier:1.15]
    ]];
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
    [self setOutput:@""];
    [self updateButtons];
    [self showWithoutChangingInput];
}

- (void)showWithoutChangingInput {
    [self positionNearPointer];
    // Do not make the panel key or activate Lore when another app supplied the text.
    [_panel orderFrontRegardless];
}

- (void)setShortcutAvailable:(BOOL)available {
    _instructions.stringValue = available ?
        @"文章を選択して⌘Cを2回押すと翻訳します。手入力は⌘↩で翻訳できます。" :
        @"選択した文章を翻訳するには「設定」で入力監視を許可してください。手入力は⌘↩で翻訳できます。";
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
    _translate.enabled = _available && hasInput;
    _translate.title = _busy ? @"再翻訳" : @"翻訳";
    _cancel.enabled = _busy;
    _copy.enabled = _output.string.length > 0;
}

- (void)translate:(id)sender {
    if (_translate.enabled && self.onTranslate) self.onTranslate(_source.string, _direction.indexOfSelectedItem);
}

- (void)cancel:(id)sender { if (self.onCancel) self.onCancel(); }
- (void)openSettings:(id)sender { if (self.onSettings) self.onSettings(); }

- (void)copyOutput:(id)sender {
    if (_output.string.length == 0) return;
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard writeObjects:@[_output.string]];
}

- (void)textDidChange:(NSNotification *)notification { [self updateButtons]; }
- (void)windowWillClose:(NSNotification *)notification { if (self.onClose) self.onClose(); }
- (void)close { [_panel close]; }
@end
