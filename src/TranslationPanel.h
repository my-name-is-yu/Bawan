#import <AppKit/AppKit.h>
#include "TranslationEngine.h"

NS_ASSUME_NONNULL_BEGIN

@class SettingsViewController;

typedef NS_ENUM(NSInteger, BawanStatusKind) {
    BawanStatusInformation, BawanStatusWarning, BawanStatusError
};

@interface TranslationPanel : NSObject
@property(nonatomic, copy, nullable) void (^onTranslate)(NSString *text, bawan::Direction direction);
@property(nonatomic, copy, nullable) void (^onCancel)(void);
@property(nonatomic, copy, nullable) void (^onClose)(void);
@property(nonatomic, copy, nullable) void (^onSettings)(void);

- (void)showForSelection:(NSString *)text;
- (void)showForManualInput;
- (void)showWithoutChangingInput;
- (void)showSettings:(SettingsViewController *)settings;
- (void)showTranslation;
- (void)setShortcutInstructions:(NSString *)instructions;
- (void)setShortcutAvailable:(BOOL)available;
- (void)setAvailable:(BOOL)available busy:(BOOL)busy status:(NSString *)status kind:(BawanStatusKind)kind;
- (void)setOutput:(NSString *)output direction:(bawan::Direction)direction;
- (void)close;
@end

NS_ASSUME_NONNULL_END
