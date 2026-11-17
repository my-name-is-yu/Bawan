#import <AppKit/AppKit.h>
#include "ShortcutBinding.h"
#include "SystemKeyboardLayout.h"

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const BawanShortcutsDidChangeNotification;
NSString *ShortcutActionTitle(bawan::ShortcutAction action);
NSString *ShortcutKeyLabel(bawan::ShortcutBinding binding);
NSString *ShortcutKeyLabel(bawan::ShortcutBinding binding, const bawan::KeyboardLayout& layout);
NSString *ShortcutBindingLabel(bawan::ShortcutBinding binding);
bawan::ShortcutBindings ShortcutDefaultBindings();
bool ShortcutIsPassiveCopy(bawan::ShortcutBinding binding);
std::uint8_t ShortcutModifiersFromFlags(NSEventModifierFlags flags, std::uint16_t keyCode = UINT16_MAX);
@interface ShortcutPreferences : NSObject
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults
                 layoutProvider:(bawan::KeyboardLayout (^)(void))provider NS_DESIGNATED_INITIALIZER;
- (instancetype)init;
- (bawan::ShortcutBindings)bindings;
- (bawan::KeyboardLayout)keyboardLayout;
- (bawan::ShortcutBinding)bindingForAction:(bawan::ShortcutAction)action;
- (BOOL)setBinding:(bawan::ShortcutBinding)binding forAction:(bawan::ShortcutAction)action
             error:(NSString * _Nullable * _Nullable)error;
- (BOOL)restoreAction:(bawan::ShortcutAction)action error:(NSString * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
