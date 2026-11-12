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
    void push(lore::EngineEvent event) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            events_.push_back(std::move(event));
        }
        changed_.notify_all();
    }

    lore::EngineEvent wait(std::uint64_t id, bool text = false) {
        std::unique_lock<std::mutex> lock(mutex_);
        const auto terminal = [id, text](const lore::EngineEvent & event) {
            if (event.requestId != id) { return false; }
            using Kind = lore::EngineEvent::Kind;
            return event.kind == Kind::Error || event.kind == Kind::Cancelled ||
                event.kind == Kind::Complete || (id == 0 && event.kind == Kind::Ready) ||
                (text && event.kind == Kind::Text);
        };
        if (!changed_.wait_for(lock, 300s, [&] {
            for (const auto & event : events_) { if (terminal(event)) { return true; } }
            return false;
        })) { throw std::runtime_error("Timed out waiting for inference"); }
        for (const auto & event : events_) { if (terminal(event)) { return event; } }
        throw std::runtime_error("Missing inference event");
    }

private:
    std::mutex mutex_;
    std::condition_variable changed_;
    std::vector<lore::EngineEvent> events_;
};

std::string completed(Events & events, std::uint64_t id,
                      lore::Direction expectedDirection = lore::Direction::Automatic) {
    const auto event = events.wait(id);
    if (event.kind != lore::EngineEvent::Kind::Complete || event.truncated || event.text.empty()) {
        throw std::runtime_error("Translation did not complete: " + event.text);
    }
    if (event.direction == lore::Direction::Automatic ||
        (expectedDirection != lore::Direction::Automatic && event.direction != expectedDirection)) {
        throw std::runtime_error("Translation output lost its resolved direction");
    }
    return event.text;
}

bool hasNonASCII(const std::string & text) {
    for (unsigned char byte : text) { if (byte >= 0x80) { return true; } }
    return false;
}

} // namespace

int main(int argc, char ** argv) {
    if (argc < 2 || argc > 3) {
        std::cerr << "Usage: engine_smoke MODEL_PATH [TEXT]\n";
        return EXIT_FAILURE;
    }
    try {
        Events events;
        lore::TranslationEngine engine([&](lore::EngineEvent event) { events.push(std::move(event)); });
        const auto started = std::chrono::steady_clock::now();
        engine.loadModel(argv[1]);
        const auto loaded = events.wait(0);
        if (loaded.kind != lore::EngineEvent::Kind::Ready) {
            throw std::runtime_error("Model did not load: " + loaded.text);
        }
        std::cerr << "model ready after " << std::chrono::duration<double>(
            std::chrono::steady_clock::now() - started).count() << " s\n";
        if (argc == 3) {
            std::cout << completed(events, engine.translate(argv[2], lore::Direction::Automatic)) << '\n';
            engine.shutdown();
            return EXIT_SUCCESS;
        }

        const std::string japanese = "会議は来週の月曜日に変更されました。";
        const auto first = completed(events, engine.translate(japanese, lore::Direction::Automatic),
                                     lore::Direction::JapaneseToEnglish);
        if (first == japanese || first.find_first_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ") == std::string::npos) {
            throw std::runtime_error("Automatic Japanese-to-English direction failed");
        }
        std::cout << "JA→EN: " << first << '\n';
        const auto second = completed(events, engine.translate(
            "The meeting has been moved to next Monday.", lore::Direction::Automatic),
            lore::Direction::EnglishToJapanese);
        if (!hasNonASCII(second)) { throw std::runtime_error("Automatic English-to-Japanese direction failed"); }
        std::cout << "EN→JA: " << second << '\n';

        if (completed(events, engine.translate(japanese, lore::Direction::JapaneseToEnglish)) != first) {
            throw std::runtime_error("Repeated greedy translation changed after another request (possible stale KV)");
        }

        const auto invalid = events.wait(engine.translate(std::string("\xFF"), lore::Direction::Automatic));
        if (invalid.kind != lore::EngineEvent::Kind::Error) { throw std::runtime_error("Invalid UTF-8 was not rejected"); }
        std::string overlong;
        for (int i = 0; i < 5000; ++i) { overlong += "hello "; }
        const auto tooLong = events.wait(engine.translate(overlong, lore::Direction::Automatic));
        if (tooLong.kind != lore::EngineEvent::Kind::Error) { throw std::runtime_error("Overlong prompt was not rejected"); }

        std::string longText;
        for (int i = 0; i < 60; ++i) {
            longText += "The application keeps one model in memory and waits for the next translation request. ";
        }
        const auto oldId = engine.translate(longText, lore::Direction::EnglishToJapanese);
        const auto streaming = events.wait(oldId, true);
        if (streaming.kind != lore::EngineEvent::Kind::Text ||
            streaming.direction != lore::Direction::EnglishToJapanese) {
            throw std::runtime_error("Long translation did not stream before completing");
        }
        const auto newId = engine.translate(japanese, lore::Direction::JapaneseToEnglish);
        if (completed(events, newId) != first) { throw std::runtime_error("Latest request inherited cancelled translation state"); }
        if (events.wait(oldId).kind != lore::EngineEvent::Kind::Cancelled) {
            throw std::runtime_error("Superseded request was not cancelled");
        }
        engine.shutdown();
        std::cout << "PASS: translation, direction, KV reset, input boundaries, streaming and cancellation\n";
        return EXIT_SUCCESS;
    } catch (const std::exception & error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
