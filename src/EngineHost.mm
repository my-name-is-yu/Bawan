#import "EngineHost.h"

#include "EngineEventMailbox.h"
#include "TranslationEngine.h"

#include <memory>
#include <utility>

@implementation EngineHost {
    void (^_handler)(const bawan::EngineEvent &);
    std::shared_ptr<bawan::EngineEventMailbox> _mailbox;
    std::unique_ptr<bawan::TranslationEngine> _engine;
}

- (instancetype)initWithEventHandler:(void (^)(const bawan::EngineEvent &))handler {
    self = [super init];
    if (self) _handler = [handler copy];
    return self;
}

- (void)deliverEventsFromMailbox:(const std::shared_ptr<bawan::EngineEventMailbox> &)mailbox {
    if (_mailbox != mailbox) return;
    for (const auto &event : mailbox->drain()) {
        if (_mailbox != mailbox) return;
        _handler(event);
    }
}

- (void)ensureEngineForModelURL:(NSURL *)modelURL {
    if (_engine) return;
    auto mailbox = std::make_shared<bawan::EngineEventMailbox>();
    __weak EngineHost *weakSelf = self;
    _engine = std::make_unique<bawan::TranslationEngine>(modelURL.fileSystemRepresentation,
        [weakSelf, mailbox](bawan::EngineEvent event) {
            if (!mailbox->push(std::move(event))) return;
            @autoreleasepool {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf deliverEventsFromMailbox:mailbox];
                });
            }
        });
    _mailbox = std::move(mailbox);
}

- (void)warmUpForModelURL:(NSURL *)modelURL {
    [self ensureEngineForModelURL:modelURL];
    _engine->warmUp();
}

- (bawan::engine::RequestId)translate:(std::string)text direction:(bawan::Direction)direction modelURL:(NSURL *)modelURL {
    [self ensureEngineForModelURL:modelURL];
    return _engine->translate(std::move(text), direction);
}

- (void)cancel {
    if (_engine) _engine->cancel();
}

- (void)releaseMemory {
    if (_engine) _engine->releaseMemory();
}

- (void)reset {
    _mailbox.reset();
    _engine.reset();
}

@end
