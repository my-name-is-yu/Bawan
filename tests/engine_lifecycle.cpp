#include "TranslationEngine.h"

#include <chrono>
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <future>
#include <cstdlib>
#include <iostream>
#include <initializer_list>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>
#include <unistd.h>

using namespace std::chrono_literals;

namespace {

using Kind = bawan::EngineEvent::Kind;
using Observation = std::pair<Kind, std::uint64_t>;

class StderrCapture {
public:
    StderrCapture() : file_(std::tmpfile()) {
        if (!file_) { throw std::runtime_error("Unable to create a diagnostic capture file"); }
        std::fflush(stderr);
        saved_ = dup(STDERR_FILENO);
        if (saved_ < 0 || dup2(fileno(file_), STDERR_FILENO) < 0) {
            if (saved_ >= 0) { close(saved_); }
            std::fclose(file_);
            throw std::runtime_error("Unable to capture engine diagnostics");
        }
    }

    ~StderrCapture() {
        if (saved_ >= 0) {
            std::fflush(stderr);
            dup2(saved_, STDERR_FILENO);
            close(saved_);
        }
        std::fclose(file_);
    }

    std::string finish() {
        std::fflush(stderr);
        if (dup2(saved_, STDERR_FILENO) < 0) {
            throw std::runtime_error("Unable to restore stderr after diagnostic capture");
        }
        close(saved_);
        saved_ = -1;
        std::rewind(file_);
        std::string result;
        char buffer[1024];
        for (std::size_t count; (count = std::fread(buffer, 1, sizeof(buffer), file_)) != 0;) {
            result.append(buffer, count);
        }
        if (std::ferror(file_)) { throw std::runtime_error("Unable to read engine diagnostics"); }
        return result;
    }

private:
    FILE * file_;
    int saved_ = -1;
};

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

    std::vector<bawan::EngineEvent> snapshot() {
        std::lock_guard<std::mutex> lock(mutex_);
        return events_;
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

    void requireSequence(std::initializer_list<Observation> expected) {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<Observation> actual;
        for (const auto & event : events_) { actual.emplace_back(event.kind, event.requestId); }
        if (actual != std::vector<Observation>(expected)) {
            std::string message = "Unexpected callback sequence:";
            for (const auto & event : actual) {
                message += " (kind=" + std::to_string(static_cast<int>(event.first)) +
                    ", requestId=" + std::to_string(event.second) + ")";
            }
            throw std::runtime_error(message);
        }
    }

private:
    std::mutex mutex_;
    std::condition_variable changed_;
    std::vector<bawan::EngineEvent> events_;
};

class LoadingGate {
public:
    explicit LoadingGate(Events & events)
        : events_(events), entered_(enter_.get_future()), resumed_(resume_.get_future().share()) {}

    void push(bawan::EngineEvent event) {
        const bool hold = event.kind == Kind::Loading && !held_.exchange(true);
        events_.push(std::move(event));
        if (hold) {
            enter_.set_value();
            resumed_.wait();
        }
    }

    void wait() {
        if (entered_.wait_for(60s) != std::future_status::ready) {
            throw std::runtime_error("The worker did not reach Loading");
        }
    }

    void release() { std::call_once(released_, [&] { resume_.set_value(); }); }

private:
    Events & events_;
    std::promise<void> enter_;
    std::future<void> entered_;
    std::promise<void> resume_;
    std::shared_future<void> resumed_;
    std::atomic<bool> held_{false};
    std::once_flag released_;
};

struct ReleaseLoadingOnExit {
    LoadingGate & gate;
    ~ReleaseLoadingOnExit() { gate.release(); }
};

void requireIncreasingIds(std::initializer_list<std::uint64_t> ids) {
    std::uint64_t previous = 0;
    for (const auto id : ids) {
        if (id <= previous) { throw std::runtime_error("Request IDs were reused or moved backwards"); }
        previous = id;
    }
}

void callbackFailuresAreObservable() {
    StderrCapture capture;
    Events events;
    bool throwLoading = true;
    bool throwRequest = true;
    bawan::TranslationEngine engine("/__bawan_tests__/missing-model.gguf",
        [&](bawan::EngineEvent event) {
            const auto kind = event.kind;
            const auto id = event.requestId;
            events.push(std::move(event));
            if (kind == Kind::Loading && std::exchange(throwLoading, false)) {
                throw std::runtime_error("callback 100% failed\nunsafe\\detail\t" +
                    std::string(300, 'x') + "PRIVATE-TAIL");
            }
            if (kind == Kind::Error && id != 0 && std::exchange(throwRequest, false)) { throw 17; }
        });
    const auto failed = engine.translate("INPUT_MUST_NOT_BE_LOGGED");
    events.requireEvent(Kind::Error, failed, 0);
    const auto retry = engine.translate("Retry after callback failure");
    events.requireEvent(Kind::Error, retry, 0);
    engine.shutdown();
    events.requireSequence({
        {Kind::Loading, 0}, {Kind::Idle, 0}, {Kind::Error, 0}, {Kind::Error, failed},
        {Kind::Loading, 0}, {Kind::Idle, 0}, {Kind::Error, 0}, {Kind::Error, retry},
    });
    const auto diagnostics = capture.finish();
    const std::string prefix = "[Bawan] TranslationEngine callback threw (event=";
    const auto first = diagnostics.find(prefix + "Loading, requestId=0): callback 100% failed\\x0Aunsafe\\x5Cdetail\\x09");
    const auto second = diagnostics.find(prefix + "Error, requestId=" + std::to_string(failed) +
        "): non-standard exception\n");
    if (first == std::string::npos || second == std::string::npos ||
        diagnostics.find(prefix, first + prefix.size()) != second ||
        diagnostics.find(prefix, second + prefix.size()) != std::string::npos ||
        diagnostics.find("...\n", first) == std::string::npos ||
        diagnostics.find("failed\nunsafe") != std::string::npos ||
        diagnostics.find("PRIVATE-TAIL") != std::string::npos ||
        diagnostics.find("INPUT_MUST_NOT_BE_LOGGED") != std::string::npos) {
        throw std::runtime_error("Callback exceptions lost their safe diagnostic details or were redelivered");
    }
}

void requestFailureKeepsLoadedModel(const std::string & modelPath) {
    Events events;
    bawan::TranslationEngine engine(modelPath,
        [&](bawan::EngineEvent event) { events.push(std::move(event)); }, 60s);
    engine.warmUp();
    events.requireEvent(Kind::Ready, 0, 0);
    const auto failed = engine.translate(std::string(1, '\xC3'));
    events.requireEvent(Kind::Error, failed, 0);
    events.requireSequence({{Kind::Loading, 0}, {Kind::Ready, 0}, {Kind::Error, failed}});
    if (events.snapshot().back().text != "The text is not valid UTF-8.") {
        throw std::runtime_error("Request failure lost its error details");
    }
    const auto recovery = engine.translate("Hello.", bawan::Direction::EnglishToJapanese);
    events.requireEvent(Kind::Complete, recovery, 0);
    engine.releaseMemory();
    events.requireEvent(Kind::Idle, 0, 0);
    engine.shutdown();
    std::vector<Observation> actual;
    bool completed = false;
    for (const auto & event : events.snapshot()) {
        if (event.kind == Kind::Text || event.kind == Kind::Complete) {
            if (event.requestId != recovery || event.direction != bawan::Direction::EnglishToJapanese ||
                event.text.empty()) {
                throw std::runtime_error("Recovery lost its request identity, direction or output");
            }
            if (event.kind == Kind::Complete) { completed = true; }
            else { continue; }
        }
        if (event.kind == Kind::Idle && !completed) {
            throw std::runtime_error("Request failure unloaded the reusable model");
        }
        actual.emplace_back(event.kind, event.requestId);
    }
    if (actual != std::vector<Observation>{{Kind::Loading, 0}, {Kind::Ready, 0},
            {Kind::Error, failed}, {Kind::Complete, recovery}, {Kind::Idle, 0}}) {
        throw std::runtime_error("Request failure emitted a global failure, reloaded or duplicated a terminal");
    }
}

void releaseKeepsLatestTranslation() {
    Events events;
    LoadingGate gate(events);
    bawan::TranslationEngine engine("/__bawan_tests__/missing-model.gguf",
        [&](bawan::EngineEvent event) { gate.push(std::move(event)); });
    ReleaseLoadingOnExit release{gate};
    engine.warmUp();
    gate.wait();
    const auto superseded = engine.translate("First");
    engine.releaseMemory();
    const auto latest = engine.translate("Latest");
    engine.warmUp();
    engine.releaseMemory();
    gate.release();
    events.requireEvent(Kind::Error, latest, 0);
    events.requireQuietFor(100ms);
    engine.shutdown();
    requireIncreasingIds({superseded, latest});
    // Replacing a translation must keep the useful in-flight load. Release
    // retains the latest queued translation, even when warm-up is also queued.
    events.requireSequence({
        {Kind::Loading, 0}, {Kind::Idle, 0}, {Kind::Error, 0},
        {Kind::Cancelled, superseded}, {Kind::Loading, 0}, {Kind::Idle, 0},
        {Kind::Error, 0}, {Kind::Error, latest},
    });
}

void releaseSupersedesWarmUp() {
    Events events;
    LoadingGate gate(events);
    bawan::TranslationEngine engine("/__bawan_tests__/missing-model.gguf",
        [&](bawan::EngineEvent event) { gate.push(std::move(event)); });
    ReleaseLoadingOnExit release{gate};
    engine.warmUp();
    gate.wait();
    engine.warmUp();
    engine.releaseMemory();
    engine.warmUp();
    gate.release();
    events.requireEvent(Kind::Error, 0, 0);
    events.requireQuietFor(100ms);
    engine.shutdown();
    events.requireSequence({{Kind::Loading, 0}, {Kind::Idle, 0}, {Kind::Error, 0}});
}

void cancelOverlappingTranslations() {
    Events events;
    LoadingGate gate(events);
    bawan::TranslationEngine engine("/__bawan_tests__/missing-model.gguf",
        [&](bawan::EngineEvent event) { gate.push(std::move(event)); });
    ReleaseLoadingOnExit release{gate};
    const auto active = engine.translate("Active");
    gate.wait();
    const auto superseded = engine.translate("Superseded");
    const auto withdrawn = engine.translate("Withdrawn");
    engine.releaseMemory();
    engine.warmUp();
    engine.cancel();
    const auto recovery = engine.translate("After cancellation");
    gate.release();
    events.requireEvent(Kind::Error, recovery, 0);
    events.requireQuietFor(100ms);
    engine.shutdown();
    requireIncreasingIds({active, superseded, withdrawn, recovery});
    events.requireSequence({
        {Kind::Loading, 0}, {Kind::Cancelled, 0}, {Kind::Cancelled, active},
        {Kind::Cancelled, superseded}, {Kind::Cancelled, withdrawn},
        {Kind::Loading, 0}, {Kind::Idle, 0}, {Kind::Error, 0}, {Kind::Error, recovery},
    });
}

void shutdownDiscardsOverlappingWork() {
    Events events;
    LoadingGate gate(events);
    bawan::TranslationEngine engine("/__bawan_tests__/missing-model.gguf",
        [&](bawan::EngineEvent event) { gate.push(std::move(event)); });
    // Release Loading before the async future is destroyed during unwinding.
    std::future<void> stopped;
    ReleaseLoadingOnExit release{gate};
    const auto active = engine.translate("Active");
    gate.wait();
    const auto superseded = engine.translate("Superseded");
    const auto withdrawn = engine.translate("Withdrawn");
    engine.releaseMemory();
    engine.cancel();
    const auto pending = engine.translate("Pending at shutdown");
    engine.warmUp();
    stopped = std::async(std::launch::async, [&] {
        engine.shutdown();
    });
    // Shutdown consumes a revision. Observe that gap through public request
    // IDs before releasing Loading, so thread scheduling cannot race the test.
    auto previous = pending;
    const auto deadline = std::chrono::steady_clock::now() + 5s;
    for (;;) {
        const auto current = engine.translate("Waiting for shutdown");
        if (current > previous + 1) { break; }
        previous = current;
        if (std::chrono::steady_clock::now() >= deadline) {
            throw std::runtime_error("Shutdown did not invalidate the held worker");
        }
        std::this_thread::sleep_for(1ms);
    }
    const auto status = stopped.wait_for(0ms);
    gate.release();
    stopped.get();
    if (status != std::future_status::timeout) {
        throw std::runtime_error("Shutdown did not join the held worker");
    }
    const auto afterShutdown = engine.translate("After shutdown");
    engine.warmUp();
    engine.releaseMemory();
    engine.cancel();
    const auto later = engine.translate("Still shut down");
    engine.shutdown();
    events.requireQuietFor(100ms);
    requireIncreasingIds({active, superseded, withdrawn, pending, afterShutdown, later});
    events.requireSequence({{Kind::Loading, 0}});
}

void pendingTranslationCompletesBeforeRelease(const std::string & modelPath, bool releaseBeforeLatest) {
    Events events;
    LoadingGate gate(events);
    bawan::TranslationEngine engine(modelPath,
        [&](bawan::EngineEvent event) { gate.push(std::move(event)); }, 60s);
    ReleaseLoadingOnExit release{gate};
    engine.warmUp();
    gate.wait();
    const auto superseded = engine.translate("The first request is replaced.");
    if (releaseBeforeLatest) { engine.releaseMemory(); }
    const auto latest = engine.translate("Hello.", bawan::Direction::EnglishToJapanese);
    if (!releaseBeforeLatest) { engine.releaseMemory(); }
    engine.warmUp();
    gate.release();
    events.requireEvent(Kind::Complete, latest, 0);
    const auto completedAt = std::chrono::steady_clock::now();
    events.requireEvent(Kind::Idle, 0, 0);
    if (std::chrono::steady_clock::now() - completedAt > 5s) {
        throw std::runtime_error("The queued release waited for the 60-second idle timeout");
    }
    engine.shutdown();

    std::vector<Observation> terminals;
    std::size_t loads = 0;
    bool completed = false;
    bool unloaded = false;
    for (const auto & event : events.snapshot()) {
        if (event.kind == Kind::Loading) { ++loads; }
        if (event.requestId != 0 &&
            (event.kind == Kind::Complete || event.kind == Kind::Cancelled || event.kind == Kind::Error)) {
            terminals.emplace_back(event.kind, event.requestId);
        }
        if (event.kind == Kind::Text || event.kind == Kind::Complete) {
            if (event.requestId != latest || event.direction != bawan::Direction::EnglishToJapanese ||
                event.text.empty()) {
                throw std::runtime_error("The retained translation lost its request identity, output or direction");
            }
        }
        if (event.kind == Kind::Complete && event.requestId == latest) { completed = true; }
        if (event.kind == Kind::Idle) {
            if (!completed) { throw std::runtime_error("Release unloaded before the pending translation completed"); }
            unloaded = true;
        }
    }
    if (loads != 1 || !unloaded ||
        terminals != std::vector<Observation>{{Kind::Cancelled, superseded}, {Kind::Complete, latest}}) {
        throw std::runtime_error("Release did not reuse the active load and finish each request exactly once");
    }
}

}

int main(int argc, char ** argv) {
    try {
        using Kind = bawan::EngineEvent::Kind;
        Events events;
        bawan::TranslationEngine engine("/__bawan_tests__/missing-model.gguf",
            [&](bawan::EngineEvent event) { events.push(std::move(event)); }, 25ms);
        events.requireQuietFor(50ms);
        if (events.mark() != 0) { throw std::runtime_error("Construction touched an unavailable model before first use"); }

        auto after = events.mark();
        const auto first = engine.translate("Hello");
        events.requireEvent(Kind::Error, first, after);
        events.requireEvent(Kind::Error, 0, after);

        after = events.mark();
        engine.warmUp();
        events.requireEvent(Kind::Error, 0, after);

        after = events.mark();
        const auto retry = engine.translate("Try again");
        events.requireEvent(Kind::Error, retry, after);
        engine.shutdown();
        events.requireQuietFor(50ms);
        events.requireSequence({
            {Kind::Loading, 0}, {Kind::Idle, 0}, {Kind::Error, 0}, {Kind::Error, first},
            {Kind::Loading, 0}, {Kind::Idle, 0}, {Kind::Error, 0},
            {Kind::Loading, 0}, {Kind::Idle, 0}, {Kind::Error, 0}, {Kind::Error, retry},
        });
        for (const auto & event : events.snapshot()) {
            if (event.kind == Kind::Error &&
                event.text != "Unable to load the model. Please check the model file.") {
                throw std::runtime_error("Load failure lost its error details");
            }
        }

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
        releaseKeepsLatestTranslation();
        releaseSupersedesWarmUp();
        cancelOverlappingTranslations();
        shutdownDiscardsOverlappingWork();
        callbackFailuresAreObservable();
        if (argc > 1) {
            requestFailureKeepsLoadedModel(argv[1]);
            pendingTranslationCompletesBeforeRelease(argv[1], true);
            pendingTranslationCompletesBeforeRelease(argv[1], false);
        }
        std::cout << "PASS: lazy construction, load/request errors, callback exception diagnostics, prewarm cancellation, retries, latest-wins, overlapping release/cancel/shutdown and exactly-once terminals\n";
        return EXIT_SUCCESS;
    } catch (const std::exception &error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
