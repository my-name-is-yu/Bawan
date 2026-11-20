#import <Foundation/Foundation.h>
#import "SelectionResult.h"

#include <cstdint>

namespace bawan {
inline constexpr int64_t selectionCopyEventTag = 0x426177616e437079;
}

NS_ASSUME_NONNULL_BEGIN

@protocol SelectionReaderEnvironment <NSObject>
- (pid_t)frontmostApplication;
- (NSInteger)pasteboardChangeCount;
- (nullable NSString *)copiedText;
- (BOOL)clipboardAccessDenied;
- (BOOL)sendCopy;
- (NSTimeInterval)uptime;
- (void)scheduleAfter:(NSTimeInterval)delay perform:(void (^)(void))callback;
@end

// Main-thread only. Each begin replaces the previous read, including queued copy events.
@interface SelectionReader : NSObject
@property(nonatomic, copy, nullable) void (^onResult)(const SelectionReadResult &result);
- (instancetype)initWithEnvironment:(id<SelectionReaderEnvironment>)environment;
// Passive copy begins before the first physical Cmd-C reaches the source app.
- (void)beginCopyFromApplication:(pid_t)application passive:(BOOL)passive;
// Call at the passive gesture's trigger, or after an active gesture's key release.
- (void)readSelection;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
