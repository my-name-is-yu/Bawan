#pragma once

#import <Foundation/Foundation.h>

#include "EngineEvent.h"

NS_ASSUME_NONNULL_BEGIN

// Use on the main thread. Events are delivered asynchronously on the main queue.
@interface EngineHost : NSObject

- (instancetype)initWithEventHandler:(void (^)(const bawan::EngineEvent &))handler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)warmUpForModelURL:(NSURL *)modelURL;
- (bawan::engine::RequestId)translate:(std::string)text direction:(bawan::Direction)direction modelURL:(NSURL *)modelURL;
- (void)cancel;
- (void)releaseMemory;
// Discard undelivered events and synchronously stop the current worker.
- (void)reset;

@end

NS_ASSUME_NONNULL_END
