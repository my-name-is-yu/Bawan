#pragma once

#import <Foundation/Foundation.h>

#include "EngineEvent.h"

NS_ASSUME_NONNULL_BEGIN

@interface EngineHost : NSObject

- (instancetype)initWithEventHandler:(void (^)(const bawan::EngineEvent &))handler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)startWithModelURL:(NSURL *)modelURL;
- (void)warmUp;
- (bawan::engine::RequestId)translate:(std::string)text direction:(bawan::Direction)direction;
- (void)cancel;
- (void)releaseMemory;
- (void)stopAndDiscardEvents;

@end

NS_ASSUME_NONNULL_END
