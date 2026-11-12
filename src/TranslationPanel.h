#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TranslationPanel : NSObject
@property(nonatomic, copy, nullable) void (^onTranslate)(NSString *text, NSInteger directionIndex);
@property(nonatomic, copy, nullable) void (^onCancel)(void);
@property(nonatomic, copy, nullable) void (^onClose)(void);
@property(nonatomic, copy, nullable) void (^onSettings)(void);
@property(nonatomic, readonly) NSInteger directionIndex;

- (void)showForSelection:(NSString *)text;
- (void)showForManualInput;
- (void)showWithoutChangingInput;
- (void)setShortcutAvailable:(BOOL)available;
- (void)setAvailable:(BOOL)available busy:(BOOL)busy status:(NSString *)status;
- (void)setOutput:(NSString *)output;
- (void)close;
@end

NS_ASSUME_NONNULL_END
