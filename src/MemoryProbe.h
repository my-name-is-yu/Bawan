#import <Foundation/Foundation.h>

#include "EngineEvent.h"

NS_ASSUME_NONNULL_BEGIN
@interface MemoryProbe : NSObject
- (instancetype)initWithDirectory:(NSString *)directory commands:(NSDictionary<NSString *, NSString *(^)(void)> *)commands;
- (void)start;
- (void)recordEngineEvent:(const bawan::EngineEvent &)event;
@end
NS_ASSUME_NONNULL_END
