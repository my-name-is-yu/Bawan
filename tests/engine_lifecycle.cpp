#include "TranslationEngine.h"

#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

using namespace std::chrono_literals;

namespace {

class Events {
public:
    void push(bawan::EngineEvent event) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            events_.push_back(std::move(event));
        }
        changed_.notify_all();
    }

    std::size_t mark() {
        std::lock_guard<std::mutex> lock(mutex_);
        return events_.size();
    }

    void requireEvent(bawan::EngineEvent::Kind kind, std::uint64_t id, std::size_t after) {
        std::unique_lock<std::mutex> lock(mutex_);
        // A cold Metal backend may compile its embedded libraries on first use.
        if (!changed_.wait_for(lock, 60s, [&] {
            for (std::size_t i = after; i < events_.size(); ++i) {
                if (events_[i].requestId == id && events_[i].kind == kind) {
                    return kind != bawan::EngineEvent::Kind::Error || !events_[i].text.empty();
                }
            }
            return false;
        })) {
            const char *kindName = "unknown";
            switch (kind) {
                case bawan::EngineEvent::Kind::Loading: kindName = "Loading"; break;
                case bawan::EngineEvent::Kind::Ready: kindName = "Ready"; break;
                case bawan::EngineEvent::Kind::Idle: kindName = "Idle"; break;
                case bawan::EngineEvent::Kind::Text: kindName = "Text"; break;
                case bawan::EngineEvent::Kind::Complete: kindName = "Complete"; break;
                case bawan::EngineEvent::Kind::Cancelled: kindName = "Cancelled"; break;
                case bawan::EngineEvent::Kind::Error: kindName = "Error"; break;
            }
            throw std::runtime_error(std::string("Timed out after 60s waiting for ") + kindName +
                                     " (requestId=" + std::to_string(id) + ")");
        }
    }

    void requireQuietFor(std::chrono::milliseconds duration) {
        std::unique_lock<std::mutex> lock(mutex_);
        const auto count = events_.size();
        if (changed_.wait_for(lock, duration, [&] { return events_.size() != count; })) {
            throw std::runtime_error("Engine construction or shutdown started model loading");
        }
    }

private:
    std::mutex mutex_;
    std::condition_variable changed_;
    std::vector<bawan::EngineEvent> events_;
};

} // namespace

int main() {
    try {
        using Kind = bawan::EngineEvent::Kind;
        Events events;
        // An unavailable file must not produce a loading/error event until use.
        bawan::TranslationEngine engine("/__bawan_tests__/missing-model.gguf",
            [&](bawan::EngineEvent event) { events.push(std::move(event)); }, 25ms);
        events.requireQuietFor(50ms);
        if (events.mark() != 0) { throw std::runtime_error("Construction touched an unavailable model before first use"); }

        auto after = events.mark();
        events.requireEvent(Kind::Error, engine.translate("Hello"), after);
        events.requireEvent(Kind::Error, 0, after);

        // A failed cold request must not leave the worker stuck or suppress a
        // subsequent prewarm failure, which is reported independently at id 0.
        after = events.mark();
        engine.warmUp();
        events.requireEvent(Kind::Error, 0, after);

        after = events.mark();
        events.requireEvent(Kind::Error, engine.translate("Try again"), after);
        engine.shutdown();
        events.requireQuietFor(50ms);

        Events unusedEvents;
        bawan::TranslationEngine unused("/__bawan_tests__/missing-model.gguf",
            [&](bawan::EngineEvent event) { unusedEvents.push(std::move(event)); });
        unused.shutdown();
        unusedEvents.requireQuietFor(50ms);
        if (unusedEvents.mark() != 0) { throw std::runtime_error("An unused engine emitted a lifecycle event"); }

        Events cancelledEvents;
        bawan::TranslationEngine *cancelledEngine = nullptr;
        bawan::TranslationEngine cancelled("/__bawan_tests__/missing-model.gguf", [&](bawan::EngineEvent event) {
            if (event.kind == Kind::Loading) cancelledEngine->cancel();
            cancelledEvents.push(std::move(event));
        }, 25ms);
        cancelledEngine = &cancelled;
        after = cancelledEvents.mark();
        cancelled.warmUp();
        // Loading is a global phase: a cancelled prewarm must terminate it even
        // without an owning translation request, so the UI can leave Loading.
        cancelledEvents.requireEvent(Kind::Cancelled, 0, after);
        cancelled.shutdown();
        std::cout << "PASS: lazy construction, cold errors, prewarm errors/cancellation, retries and unused shutdown\n";
        return EXIT_SUCCESS;
    } catch (const std::exception &error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
