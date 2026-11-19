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

    bawan::EngineEvent wait(std::uint64_t id, bool text = false) {
        std::unique_lock<std::mutex> lock(mutex_);
        const auto terminal = [id, text](const bawan::EngineEvent & event) {
            if (event.requestId != id) { return false; }
            using Kind = bawan::EngineEvent::Kind;
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

    std::size_t mark() {
        std::lock_guard<std::mutex> lock(mutex_);
        return events_.size();
    }

    void waitKind(bawan::EngineEvent::Kind kind, std::size_t after) {
        std::unique_lock<std::mutex> lock(mutex_);
        if (!changed_.wait_for(lock, 300s, [&] {
            for (std::size_t i = after; i < events_.size(); ++i) {
                if (events_[i].kind == kind) return true;
            }
            return false;
        })) { throw std::runtime_error("Timed out waiting for an engine lifecycle event"); }
    }

    std::size_t count(bawan::EngineEvent::Kind kind, std::size_t after) {
        std::lock_guard<std::mutex> lock(mutex_);
        std::size_t count = 0;
        for (std::size_t i = after; i < events_.size(); ++i) {
            if (events_[i].kind == kind) ++count;
        }
        return count;
    }

    void requireNoIdleBeforeCompletion(std::uint64_t id, std::size_t after) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (std::size_t i = after; i < events_.size(); ++i) {
            if (events_[i].kind == bawan::EngineEvent::Kind::Idle) {
                throw std::runtime_error("The model was unloaded during an active translation");
            }
            if (events_[i].requestId == id && events_[i].kind == bawan::EngineEvent::Kind::Complete) return;
        }
        throw std::runtime_error("Missing completed translation");
    }

    void requireNoOutput(std::uint64_t id) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (const auto & event : events_) {
            if (event.requestId == id && (event.kind == bawan::EngineEvent::Kind::Text ||
                                         event.kind == bawan::EngineEvent::Kind::Complete)) {
                throw std::runtime_error("A cancelled model load produced translation output");
            }
        }
    }

    void requireQuietFor(std::chrono::milliseconds duration) {
        std::unique_lock<std::mutex> lock(mutex_);
        const auto count = events_.size();
        if (changed_.wait_for(lock, duration, [&] { return events_.size() != count; })) {
            throw std::runtime_error("The idle or shut-down engine emitted an unexpected event");
        }
    }

private:
    std::mutex mutex_;
    std::condition_variable changed_;
    std::vector<bawan::EngineEvent> events_;
};

std::string completed(Events & events, std::uint64_t id,
                      bawan::Direction expectedDirection = bawan::Direction::Automatic) {
    const auto event = events.wait(id);
    if (event.kind != bawan::EngineEvent::Kind::Complete || event.truncated || event.text.empty()) {
        throw std::runtime_error("Translation did not complete: " + event.text);
    }
    if (event.direction == bawan::Direction::Automatic ||
        (expectedDirection != bawan::Direction::Automatic && event.direction != expectedDirection)) {
        throw std::runtime_error("Translation output lost its resolved direction");
    }
    return event.text;
}

bool hasNonASCII(const std::string & text) {
    for (unsigned char byte : text) { if (byte >= 0x80) { return true; } }
    return false;
}

}

int main(int argc, char ** argv) {
    if (argc < 2 || argc > 3) {
        std::cerr << "Usage: engine_smoke MODEL_PATH [TEXT]\n";
        return EXIT_FAILURE;
    }
    try {
        using Kind = bawan::EngineEvent::Kind;
        constexpr auto idleTimeout = 500ms;
        Events events;
        bawan::TranslationEngine engine(argv[1], [&](bawan::EngineEvent event) { events.push(std::move(event)); }, idleTimeout);
        events.requireQuietFor(50ms);
        if (events.mark() != 0) { throw std::runtime_error("Construction started model loading before first use"); }
        const auto started = std::chrono::steady_clock::now();
        if (argc == 3) {
            std::cout << completed(events, engine.translate(argv[2], bawan::Direction::Automatic)) << '\n';
            engine.shutdown();
            return EXIT_SUCCESS;
        }

        const std::string japanese = "会議は来週の月曜日に変更されました。";
        const auto coldStart = events.mark();
        const auto firstId = engine.translate(japanese, bawan::Direction::Automatic);
        const auto first = completed(events, firstId,
                                     bawan::Direction::JapaneseToEnglish);
        events.requireNoIdleBeforeCompletion(firstId, coldStart);
        std::cerr << "cold translation completed after " << std::chrono::duration<double>(
            std::chrono::steady_clock::now() - started).count() << " s\n";
        if (first == japanese || first.find_first_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ") == std::string::npos) {
            throw std::runtime_error("Automatic Japanese-to-English direction failed");
        }
        std::cout << "JA→EN: " << first << '\n';
        const auto second = completed(events, engine.translate(
            "The meeting has been moved to next Monday.", bawan::Direction::Automatic),
            bawan::Direction::EnglishToJapanese);
        if (!hasNonASCII(second)) { throw std::runtime_error("Automatic English-to-Japanese direction failed"); }
        std::cout << "EN→JA: " << second << '\n';

        const auto word = completed(events, engine.translate("ephemeral", bawan::Direction::EnglishToJapanese),
                                    bawan::Direction::EnglishToJapanese);
        if (word.find("儚") == std::string::npos && word.find("はかな") == std::string::npos &&
            word.find("一時") == std::string::npos && word.find("短命") == std::string::npos &&
            word.find("束の間") == std::string::npos) {
            throw std::runtime_error("Short word lost its meaning: " + word);
        }
        const auto invitation = completed(events, engine.translate("You're welcome to join.", bawan::Direction::Automatic),
                                          bawan::Direction::EnglishToJapanese);
        if (invitation.find("参加") == std::string::npos && invitation.find("加わ") == std::string::npos &&
            invitation.find("仲間") == std::string::npos) {
            throw std::runtime_error("Short invitation lost its meaning: " + invitation);
        }
        const auto cafe = completed(events, engine.translate(u8"café", bawan::Direction::Automatic),
                                    bawan::Direction::EnglishToJapanese);
        if (cafe.find("カフェ") == std::string::npos && cafe.find("喫茶") == std::string::npos &&
            cafe.find("コーヒー") == std::string::npos) {
            throw std::runtime_error("Accented short word lost its meaning: " + cafe);
        }
        const auto cafeInvitation = completed(events, engine.translate(u8"Let's meet at the café.", bawan::Direction::Automatic),
                                              bawan::Direction::EnglishToJapanese);
        if (cafeInvitation.find("会") == std::string::npos && cafeInvitation.find("集合") == std::string::npos &&
            cafeInvitation.find("待ち合") == std::string::npos) {
            throw std::runtime_error("Accented invitation lost its meaning: " + cafeInvitation);
        }
        const auto idiom = completed(events, engine.translate("on the fence", bawan::Direction::Automatic),
                                     bawan::Direction::EnglishToJapanese);
        // Quantized inference can vary by GPU backend; check completion and
        // direction here without pinning a particular idiom interpretation.
        if (!hasNonASCII(idiom)) throw std::runtime_error("Short idiom did not produce Japanese: " + idiom);
        completed(events, engine.translate("Please do not leave just yet.", bawan::Direction::Automatic),
                  bawan::Direction::EnglishToJapanese);
        std::cout << "Short EN→JA: " << word << " / " << invitation << " / " << cafe << " / "
                  << cafeInvitation << " / " << idiom << '\n';

        if (completed(events, engine.translate(japanese, bawan::Direction::JapaneseToEnglish)) != first) {
            throw std::runtime_error("Repeated greedy translation changed after another request (possible stale KV)");
        }

        const auto warmBurst = events.mark();
        engine.warmUp();
        const auto warmId = engine.translate(japanese, bawan::Direction::JapaneseToEnglish);
        engine.warmUp();
        if (completed(events, warmId) != first) {
            throw std::runtime_error("Warm-up interrupted a translation or changed its independent context");
        }
        if (events.count(Kind::Loading, warmBurst) != 0) {
            throw std::runtime_error("Warm-up reloaded an already resident model");
        }

        const std::string invalidInputs[] = {
            "\xFF", "\x80", "\xC0\xAF", "\xE0\x80\xAF", "\xED\xA0\x80",
            "\xF4\x90\x80\x80", "\xE2\x82", "\xE2!", "\xF0\x90\x80",
        };
        for (const auto &input : invalidInputs) {
            const auto invalid = events.wait(engine.translate(input, bawan::Direction::Automatic));
            if (invalid.kind != bawan::EngineEvent::Kind::Error) {
                throw std::runtime_error("Invalid or incomplete UTF-8 was not rejected");
            }
            events.requireNoOutput(invalid.requestId);
        }
        if (completed(events, engine.translate(japanese, bawan::Direction::JapaneseToEnglish)) != first) {
            throw std::runtime_error("Translation did not recover after invalid UTF-8");
        }
        std::string overlong;
        for (int i = 0; i < 5000; ++i) { overlong += "hello "; }
        const auto tooLong = events.wait(engine.translate(overlong, bawan::Direction::Automatic));
        if (tooLong.kind != bawan::EngineEvent::Kind::Error) { throw std::runtime_error("Overlong prompt was not rejected"); }
        events.requireNoOutput(tooLong.requestId);
        std::string largePaste;
        largePaste.reserve(2 * 1024 * 1024);
        while (largePaste.size() < 2 * 1024 * 1024) largePaste += "hello ";
        const auto rejectedPaste = events.wait(engine.translate(largePaste, bawan::Direction::EnglishToJapanese));
        if (rejectedPaste.kind != bawan::EngineEvent::Kind::Error ||
            rejectedPaste.text.find("4,096 tokens") == std::string::npos) {
            throw std::runtime_error("Large pasted input was not rejected by the prompt budget");
        }
        events.requireNoOutput(rejectedPaste.requestId);
        if (completed(events, engine.translate(japanese, bawan::Direction::JapaneseToEnglish)) != first) {
            throw std::runtime_error("Translation did not recover after an overlong prompt");
        }

        // The pinned PLaMo vocabulary has single tokens for "hello" and " hello".
        // This crosses its 2,048-token sliding window while staying below the
        // 4,096-token prompt limit. Cancel after prefill to bound generation cost.
        std::string slidingWindowText;
        for (int i = 0; i < 2300; ++i) { slidingWindowText += "hello "; }
        const auto cancelledId = engine.translate(slidingWindowText, bawan::Direction::EnglishToJapanese);
        const auto beforeCancel = events.wait(cancelledId, true);
        if (beforeCancel.kind != bawan::EngineEvent::Kind::Text ||
            beforeCancel.direction != bawan::Direction::EnglishToJapanese) {
            throw std::runtime_error("Prompt spanning the sliding window did not stream");
        }
        engine.cancel();
        if (events.wait(cancelledId).kind != bawan::EngineEvent::Kind::Cancelled) {
            throw std::runtime_error("Explicit cancellation did not stop the long translation");
        }
        if (completed(events, engine.translate(japanese, bawan::Direction::JapaneseToEnglish)) != first) {
            throw std::runtime_error("Translation inherited state after explicit cancellation");
        }

        std::string longText;
        for (int i = 0; i < 60; ++i) {
            longText += "The application keeps one model in memory and waits for the next translation request. ";
        }
        const auto finalBurst = events.mark();
        const auto oldId = engine.translate(longText, bawan::Direction::EnglishToJapanese);
        const auto streaming = events.wait(oldId, true);
        if (streaming.kind != bawan::EngineEvent::Kind::Text ||
            streaming.direction != bawan::Direction::EnglishToJapanese) {
            throw std::runtime_error("Long translation did not stream before completing");
        }
        const auto newId = engine.translate(japanese, bawan::Direction::JapaneseToEnglish);
        if (completed(events, newId) != first) { throw std::runtime_error("Latest request inherited cancelled translation state"); }
        if (events.wait(oldId).kind != bawan::EngineEvent::Kind::Cancelled) {
            throw std::runtime_error("Superseded request was not cancelled");
        }
        events.requireNoIdleBeforeCompletion(newId, finalBurst);
        events.waitKind(Kind::Idle, finalBurst);

        const auto afterIdle = events.mark();
        const auto reloadedId = engine.translate(japanese, bawan::Direction::JapaneseToEnglish);
        if (completed(events, reloadedId) != first) {
            throw std::runtime_error("Translation changed after idle unloading and reloading");
        }
        if (events.count(Kind::Loading, afterIdle) != 1) {
            throw std::runtime_error("The model was not reloaded once after idle unloading");
        }
        events.requireNoIdleBeforeCompletion(reloadedId, afterIdle);
        engine.shutdown();
        events.requireQuietFor(2 * idleTimeout);

        Events interruptedEvents;
        bawan::TranslationEngine *interruptedEngine = nullptr;
        bool cancelNextLoad = true;
        bawan::TranslationEngine interrupted(argv[1], [&](bawan::EngineEvent event) {
            if (event.kind == Kind::Loading && cancelNextLoad) {
                cancelNextLoad = false;
                interruptedEngine->cancel();
            }
            interruptedEvents.push(std::move(event));
        }, idleTimeout);
        interruptedEngine = &interrupted;
        const auto interruptedId = interrupted.translate(japanese, bawan::Direction::JapaneseToEnglish);
        if (interruptedEvents.wait(interruptedId).kind != Kind::Cancelled) {
            throw std::runtime_error("Cancellation during cold model loading was not honored");
        }
        interruptedEvents.requireNoOutput(interruptedId);
        if (completed(interruptedEvents, interrupted.translate(japanese, bawan::Direction::JapaneseToEnglish)) != first) {
            throw std::runtime_error("Translation did not recover after cancelling a model load");
        }
        interruptedEvents.requireNoOutput(interruptedId);
        interrupted.shutdown();

        Events pressureEvents;
        bawan::TranslationEngine pressured(argv[1], [&](bawan::EngineEvent event) {
            pressureEvents.push(std::move(event));
        }, 60s);
        const auto pressureStart = pressureEvents.mark();
        const auto pressuredId = pressured.translate(
            "The application keeps one model in memory and waits for the next translation request. "
            "It releases that model when the system needs memory back.", bawan::Direction::EnglishToJapanese);
        if (pressureEvents.wait(pressuredId, true).kind != Kind::Text) {
            throw std::runtime_error("Translation before memory release did not stream");
        }
        auto releasedAt = std::chrono::steady_clock::now();
        pressured.releaseMemory();
        completed(pressureEvents, pressuredId, bawan::Direction::EnglishToJapanese);
        pressureEvents.requireNoIdleBeforeCompletion(pressuredId, pressureStart);
        pressureEvents.waitKind(Kind::Idle, pressureStart);
        if (std::chrono::steady_clock::now() - releasedAt > 30s) {
            throw std::runtime_error("Memory release waited for the idle timeout");
        }
        const auto afterRelease = pressureEvents.mark();
        pressured.releaseMemory();
        pressureEvents.requireQuietFor(200ms);
        if (completed(pressureEvents, pressured.translate(japanese, bawan::Direction::JapaneseToEnglish)) != first) {
            throw std::runtime_error("Translation changed after releasing memory");
        }
        if (pressureEvents.count(Kind::Loading, afterRelease) != 1) {
            throw std::runtime_error("The model was not reloaded once after releasing memory");
        }
        const auto warmRelease = pressureEvents.mark();
        releasedAt = std::chrono::steady_clock::now();
        pressured.releaseMemory();
        pressureEvents.waitKind(Kind::Idle, warmRelease);
        if (std::chrono::steady_clock::now() - releasedAt > 5s) {
            throw std::runtime_error("An idle resident model was not released promptly");
        }
        pressured.shutdown();
        std::cout << "PASS: lazy loading, warm-up, idle unloading/reloading, memory release, translation, short input, direction, input boundaries, error recovery, sliding window, streaming and cancellation\n";
        return EXIT_SUCCESS;
    } catch (const std::exception & error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
