#import "ShortcutMonitor.h"

@class SelectionReader;

NS_ASSUME_NONNULL_BEGIN

@interface ShortcutMonitor (Testing)
- (instancetype)initWithPreferences:(ShortcutPreferences *)preferences selectionReader:(SelectionReader *)selectionReader;
@end

NS_ASSUME_NONNULL_END
