#import <AppKit/AppKit.h>
#include "ShortcutBinding.h"

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const LoreShortcutsDidChangeNotification;
NSString *ShortcutActionTitle(lore::ShortcutAction action);
NSString *ShortcutKeyLabel(lore::ShortcutBinding binding);
NSString *ShortcutBindingLabel(lore::ShortcutBinding binding);
std::uint8_t ShortcutModifiersFromFlags(NSEventModifierFlags flags, std::uint16_t keyCode = UINT16_MAX);
@interface ShortcutPreferences : NSObject
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults NS_DESIGNATED_INITIALIZER;
- (instancetype)init;
- (lore::ShortcutBindings)bindings;
- (lore::ShortcutBinding)bindingForAction:(lore::ShortcutAction)action;
- (BOOL)setBinding:(lore::ShortcutBinding)binding forAction:(lore::ShortcutAction)action
             error:(NSString * _Nullable * _Nullable)error;
- (BOOL)restoreAction:(lore::ShortcutAction)action error:(NSString * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
