#include "TranslationEngine.h"

#include <chrono>
#include <atomic>
#include <condition_variable>
#include <future>
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
            throw std::runtime_error("The engine emitted an event while it had no work");
        }
    }

private:
    std::mutex mutex_;
    std::condition_variable changed_;
    std::vector<bawan::EngineEvent> events_;
};

}

int main() {
    try {
        using Kind = bawan::EngineEvent::Kind;
        Events events;
        bawan::TranslationEngine engine("/__bawan_tests__/missing-model.gguf",
            [&](bawan::EngineEvent event) { events.push(std::move(event)); }, 25ms);
        events.requireQuietFor(50ms);
        if (events.mark() != 0) { throw std::runtime_error("Construction touched an unavailable model before first use"); }

        auto after = events.mark();
        events.requireEvent(Kind::Error, engine.translate("Hello"), after);
        events.requireEvent(Kind::Error, 0, after);

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
        cancelledEvents.requireEvent(Kind::Cancelled, 0, after);
        cancelled.shutdown();

        Events replacedEvents;
        std::promise<void> loadingSeen;
        std::promise<void> resume;
        auto resumed = resume.get_future().share();
        std::atomic<bool> held{false};
        bawan::TranslationEngine replaced("/__bawan_tests__/missing-model.gguf", [&](bawan::EngineEvent event) {
            const bool hold = event.kind == Kind::Loading && !held.exchange(true);
            replacedEvents.push(std::move(event));
            if (hold) {
                loadingSeen.set_value();
                resumed.wait();
            }
        }, 25ms);
        after = replacedEvents.mark();
        replaced.warmUp();
        loadingSeen.get_future().wait();
        const auto superseded = replaced.translate("First");
        const auto latest = replaced.translate("Second");
        const auto withdrawn = replaced.translate("Third");
        replaced.cancel();
        resume.set_value();
        replacedEvents.requireEvent(Kind::Cancelled, superseded, after);
        replacedEvents.requireEvent(Kind::Cancelled, latest, after);
        replacedEvents.requireEvent(Kind::Cancelled, withdrawn, after);
        replacedEvents.requireQuietFor(200ms);
        replaced.shutdown();
        std::cout << "PASS: lazy construction, cold errors, prewarm errors/cancellation, retries, unused shutdown and replaced-request cancellation\n";
        return EXIT_SUCCESS;
    } catch (const std::exception &error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
