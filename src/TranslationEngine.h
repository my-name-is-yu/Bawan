#pragma once

#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace lore {

enum class Direction { Automatic, EnglishToJapanese, JapaneseToEnglish };

struct EngineEvent {
    enum class Kind { Loading, Ready, Idle, Text, Complete, Cancelled, Error };
    Kind kind;
    std::uint64_t requestId = 0;
    // Text events contain the complete, valid UTF-8 translation so far.
    std::string text;
    bool truncated = false;
    // Text and Complete carry the concrete direction used for this output.
    Direction direction = Direction::Automatic;
};

// Own one instance for the application. Callbacks run on the inference worker;
// dispatch UI work to the main thread. Destroy/shutdown from the owning thread.
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
    std::uint64_t translate(std::string text, Direction direction = Direction::Automatic);
    void cancel();
    void shutdown();

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace lore
