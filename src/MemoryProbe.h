#import <Foundation/Foundation.h>

#include "TranslationEngine.h"

NS_ASSUME_NONNULL_BEGIN
@interface MemoryProbe : NSObject
- (instancetype)initWithDirectory:(NSString *)directory commands:(NSDictionary<NSString *, NSString *(^)(void)> *)commands;
- (void)start;
- (void)recordEngineEvent:(bawan::EngineEvent::Kind)kind;
@end
NS_ASSUME_NONNULL_END
