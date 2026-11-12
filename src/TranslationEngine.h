#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace lore {

enum class Direction { Automatic, EnglishToJapanese, JapaneseToEnglish };

struct EngineEvent {
    enum class Kind { Loading, Ready, Text, Complete, Cancelled, Error };
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
class TranslationEngine final {
public:
    using Callback = std::function<void(EngineEvent)>;

    explicit TranslationEngine(Callback callback);
    ~TranslationEngine();
    TranslationEngine(const TranslationEngine &) = delete;
    TranslationEngine & operator=(const TranslationEngine &) = delete;

    void loadModel(std::string path);
    std::uint64_t translate(std::string text, Direction direction = Direction::Automatic);
    void cancel();
    void shutdown();

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace lore
