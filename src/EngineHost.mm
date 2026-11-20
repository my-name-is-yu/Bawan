#import "EngineHost.h"

#import "ApplicationRunLoop.h"
#include "EngineEventMailbox.h"
#include "TranslationEngine.h"

#include <memory>
#include <utility>

namespace {

struct Stopped {};

struct Running {
    std::string modelPath;
    std::shared_ptr<bawan::EngineEventMailbox> mailbox;
    bawan::TranslationEngine engine;

    Running(std::string path, std::shared_ptr<bawan::EngineEventMailbox> events,
            bawan::TranslationEngine::Callback callback)
        : modelPath(std::move(path)), mailbox(std::move(events)), engine(modelPath, std::move(callback)) {}
};

}

@implementation EngineHost {
    void (^_handler)(const bawan::EngineEvent &);
    std::variant<Stopped, Running> _state;
}

- (instancetype)initWithEventHandler:(void (^)(const bawan::EngineEvent &))handler {
    dispatch_assert_queue(dispatch_get_main_queue());
    self = [super init];
    if (self) _handler = [handler copy];
    return self;
}

- (BOOL)ownsMailbox:(const std::shared_ptr<bawan::EngineEventMailbox> &)mailbox {
    const auto *running = std::get_if<Running>(&_state);
    return running && running->mailbox == mailbox;
}

- (void)deliverEventsFromMailbox:(const std::shared_ptr<bawan::EngineEventMailbox> &)mailbox {
    if (![self ownsMailbox:mailbox]) return;
    for (const auto &event : mailbox->drain()) {
        if (![self ownsMailbox:mailbox]) return;
        _handler(event);
    }
}

- (void)startWithModelURL:(NSURL *)modelURL {
    dispatch_assert_queue(dispatch_get_main_queue());
    std::string path(modelURL.fileSystemRepresentation);
    const auto *running = std::get_if<Running>(&_state);
    if (running && running->modelPath == path) return;
    _state.emplace<Stopped>();
    auto mailbox = std::make_shared<bawan::EngineEventMailbox>();
    __weak EngineHost *weakSelf = self;
    _state.emplace<Running>(std::move(path), mailbox,
        [weakSelf, mailbox](bawan::EngineEvent event) {
            if (!mailbox->push(std::move(event))) return;
            @autoreleasepool {
                PerformInApplicationRunLoop(^{
                    [weakSelf deliverEventsFromMailbox:mailbox];
                });
            }
        });
}

- (BOOL)warmUp {
    dispatch_assert_queue(dispatch_get_main_queue());
    auto *running = std::get_if<Running>(&_state);
    if (!running) return NO;
    running->engine.warmUp();
    return YES;
}

- (std::optional<bawan::engine::RequestId>)translate:(std::string)text direction:(bawan::Direction)direction {
    dispatch_assert_queue(dispatch_get_main_queue());
    if (auto *running = std::get_if<Running>(&_state)) {
        return running->engine.translate(std::move(text), direction);
    }
    return std::nullopt;
}

- (void)cancel {
    dispatch_assert_queue(dispatch_get_main_queue());
    if (auto *running = std::get_if<Running>(&_state)) running->engine.cancel();
}

- (void)releaseMemory {
    dispatch_assert_queue(dispatch_get_main_queue());
    if (auto *running = std::get_if<Running>(&_state)) running->engine.releaseMemory();
}

- (void)stopAndDiscardEvents {
    dispatch_assert_queue(dispatch_get_main_queue());
    _state.emplace<Stopped>();
}

@end
