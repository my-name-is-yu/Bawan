#pragma once

#include "EngineEvent.h"

#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace bawan {

// Own one instance for the application. Callbacks run on the inference worker;
// dispatch UI work to the main thread. Destroy/shutdown from the owning thread.
// Callbacks must return promptly and must not wait on the owning thread during
// shutdown. Callback exceptions are logged to stderr without retrying delivery.
// Construction does not initialize the inference backend or load the model.
// The first warmUp/translate loads it; inactivity releases it and the backend.
// Each translation owns its context until completion, cancellation or error.
// Terminal callbacks run after that context is released; Idle follows unloading.
class TranslationEngine final {
public:
    using Callback = std::function<void(EngineEvent)>;

    TranslationEngine(std::string modelPath, Callback callback,
                      std::chrono::milliseconds idleTimeout = std::chrono::seconds(60));
    ~TranslationEngine();
    TranslationEngine(const TranslationEngine &) = delete;
    TranslationEngine & operator=(const TranslationEngine &) = delete;

    // Optional prewarming is idempotent and never interrupts a translation.
    void warmUp();
    engine::RequestId translate(std::string text, Direction direction = Direction::Automatic);
    void cancel();
    // Unload the model now, or as soon as the active translation finishes.
    void releaseMemory();
    // Cancel pending/active work and synchronously join the worker. This waits
    // for any executing callback and non-interruptible backend operation; no
    // fixed duration is guaranteed. On return worker resources are released
    // and no further callbacks can run.
    void shutdown();

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};

}
