#include "TranslationEngine.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <sys/resource.h>
#include <thread>
#include <unistd.h>
#include <utility>

#if defined(__APPLE__)
#include <mach/mach.h>
#endif

namespace {

using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;

struct Usage {
    double cpuSeconds;
    std::int64_t currentRSS = -1;
    std::int64_t physicalFootprint = -1;
    std::int64_t maximumRSS = -1;
};

Usage usage() {
    rusage resource{};
    if (getrusage(RUSAGE_SELF, &resource) != 0) {
        throw std::runtime_error("getrusage failed");
    }
    Usage result;
    result.cpuSeconds = resource.ru_utime.tv_sec + resource.ru_utime.tv_usec / 1e6 +
        resource.ru_stime.tv_sec + resource.ru_stime.tv_usec / 1e6;
#if defined(__APPLE__)
    // macOS reports ru_maxrss in bytes; Linux reports it in KiB.
    result.maximumRSS = resource.ru_maxrss;
    mach_task_basic_info_data_t basic{};
    mach_msg_type_number_t basicCount = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  reinterpret_cast<task_info_t>(&basic), &basicCount) == KERN_SUCCESS) {
        result.currentRSS = static_cast<std::int64_t>(basic.resident_size);
    }
    task_vm_info_data_t memory{};
    mach_msg_type_number_t memoryCount = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO,
                  reinterpret_cast<task_info_t>(&memory), &memoryCount) == KERN_SUCCESS) {
        result.physicalFootprint = static_cast<std::int64_t>(memory.phys_footprint);
    }
#elif defined(__linux__)
    result.maximumRSS = static_cast<std::int64_t>(resource.ru_maxrss) * 1024;
    std::ifstream statm("/proc/self/statm");
    std::int64_t virtualPages = 0;
    std::int64_t residentPages = 0;
    const long pageSize = sysconf(_SC_PAGESIZE);
    if (pageSize > 0 && (statm >> virtualPages >> residentPages)) {
        result.currentRSS = residentPages * pageSize;
    }
#endif
    return result;
}

struct Result {
    bawan::EngineEvent event;
    std::optional<Clock::time_point> firstText;
    Clock::time_point completed;
    std::int64_t observedTextRSS = -1;
    std::int64_t observedTextFootprint = -1;
};

// Keep one model-state event and one translation event, not event history.
class LatestEvent {
public:
    void push(bawan::EngineEvent event) {
        const auto arrived = Clock::now();
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (event.requestId == 0) {
                state_ = std::move(event);
                stateTime_ = arrived;
            } else {
                if (!latest_ || latest_->requestId != event.requestId) {
                    firstText_.reset();
                    observedTextRSS_ = -1;
                    observedTextFootprint_ = -1;
                }
                if (event.kind == bawan::EngineEvent::Kind::Text) {
                    if (!firstText_) { firstText_ = arrived; }
                    // Capture arrival before sampling so first-text latency excludes
                    // this callback's diagnostic work. These are observations, not
                    // continuously sampled process peaks.
                    const auto sample = usage();
                    observedTextRSS_ = std::max(observedTextRSS_, sample.currentRSS);
                    observedTextFootprint_ = std::max(observedTextFootprint_, sample.physicalFootprint);
                }
                latest_ = std::move(event);
                latestTime_ = arrived;
            }
        }
        changed_.notify_one();
    }

    Result wait(std::uint64_t id,
                bawan::EngineEvent::Kind expected = bawan::EngineEvent::Kind::Complete) {
        std::unique_lock<std::mutex> lock(mutex_);
        const auto & event = id == 0 ? state_ : latest_;
        if (!changed_.wait_for(lock, 60s, [&] {
            if (!event || event->requestId != id) { return false; }
            using Kind = bawan::EngineEvent::Kind;
            return event->kind == expected || event->kind == Kind::Error || event->kind == Kind::Cancelled;
        })) { throw std::runtime_error("Inference timed out after 60 seconds"); }
        if (id == 0) { return Result{*state_, std::nullopt, stateTime_}; }
        return Result{*latest_, firstText_, latestTime_, observedTextRSS_, observedTextFootprint_};
    }

private:
    std::mutex mutex_;
    std::condition_variable changed_;
    std::optional<bawan::EngineEvent> state_;
    Clock::time_point stateTime_;
    std::optional<bawan::EngineEvent> latest_;
    std::optional<Clock::time_point> firstText_;
    Clock::time_point latestTime_;
    std::int64_t observedTextRSS_ = -1;
    std::int64_t observedTextFootprint_ = -1;
};

double milliseconds(Clock::time_point begin, Clock::time_point end) {
    return std::chrono::duration<double, std::milli>(end - begin).count();
}

void memoryMetrics(const char * phase, const Usage & sample) {
    std::cout << "current_rss_" << phase << "_bytes=" << sample.currentRSS << '\n'
              << "physical_footprint_" << phase << "_bytes=" << sample.physicalFootprint << '\n'
              << "max_rss_" << phase << "_bytes=" << sample.maximumRSS << '\n';
}

} // namespace

int main(int argc, char ** argv) {
    if (argc != 2) {
        std::cerr << "Usage: engine_profile MODEL_PATH\n";
        return EXIT_FAILURE;
    }
    try {
        using Kind = bawan::EngineEvent::Kind;
        std::cout << std::fixed << std::setprecision(3)
                  << "unavailable_metric_value=-1\n"
                  << "memory_note=RSS includes resident mapped pages; macOS physical footprint is separate; do not add them\n"
                  << "observed_text_memory_note=Sampled in Text callbacks, not continuous process peaks; sampling adds diagnostic overhead\n"
                  << "profile_idle_timeout_ms=1000\n";
        memoryMetrics("before_engine", usage());
        LatestEvent events;
        bawan::TranslationEngine engine(argv[1],
            [&](bawan::EngineEvent event) { events.push(std::move(event)); }, 1s);
        memoryMetrics("after_constructor", usage());
        const auto idleStart = Clock::now();
        const auto beforeIdle = usage();
        std::this_thread::sleep_for(5s);
        const auto afterIdle = usage();
        const double idleWall = std::chrono::duration<double>(Clock::now() - idleStart).count();
        const double idleCPU = afterIdle.cpuSeconds - beforeIdle.cpuSeconds;
        std::cout << "idle_phase=cold_startup\n"
                  << "idle_wall_seconds=" << idleWall << '\n'
                  << "idle_cpu_seconds=" << idleCPU << '\n'
                  << "idle_cpu_percent_one_core=" << 100.0 * idleCPU / idleWall << '\n';
        memoryMetrics("cold_startup", afterIdle);

        const auto loadStarted = Clock::now();
        engine.warmUp();
        const auto loaded = events.wait(0, Kind::Ready);
        if (loaded.event.kind != Kind::Ready) {
            throw std::runtime_error("Model did not become ready: " + loaded.event.text);
        }
        std::cout << "model_load_ms=" << milliseconds(loadStarted, loaded.completed) << '\n';
        memoryMetrics("after_load", usage());

        constexpr std::size_t totalRequests = 20;
        constexpr std::size_t warmupRequests = 2;
        constexpr std::array<const char *, 4> corpus = {
            "会議は来週の月曜日に変更されました。",
            "The application keeps one model in memory and waits for a translation request.",
            "翻訳が終わったら、結果をコピーして元の作業に戻れます。",
            "Please review the document before tomorrow's meeting."
        };
        std::cout << "total_requests=" << totalRequests << '\n'
                  << "warmup_requests=" << warmupRequests << '\n'
                  << "iteration,direction,first_token_ms,completion_ms,current_rss_bytes,physical_footprint_bytes,max_rss_bytes,observed_text_rss_max_bytes,observed_text_physical_footprint_max_bytes\n";
        Usage afterWarmup{};
        Usage finalUsage{};
        std::int64_t minimumSteadyRSS = -1;
        std::int64_t maximumSteadyRSS = -1;
        std::int64_t observedTextRSSAfterWarmup = -1;
        std::int64_t observedTextFootprintAfterWarmup = -1;
        double firstTokenTotal = 0;
        double completionTotal = 0;
        for (std::size_t iteration = 0; iteration < totalRequests; ++iteration) {
            const auto started = Clock::now();
            const auto id = engine.translate(corpus[iteration % corpus.size()], bawan::Direction::Automatic);
            const auto result = events.wait(id);
            if (result.event.kind != bawan::EngineEvent::Kind::Complete ||
                result.event.truncated || result.event.text.empty() || !result.firstText) {
                throw std::runtime_error("Request " + std::to_string(iteration + 1) + " did not complete normally");
            }
            const auto sample = usage();
            const auto firstToken = milliseconds(started, *result.firstText);
            const auto completion = milliseconds(started, result.completed);
            std::cout << iteration + 1 << ',' << (iteration % 2 == 0 ? "ja_to_en" : "en_to_ja")
                      << ',' << firstToken << ',' << completion << ',' << sample.currentRSS
                      << ',' << sample.physicalFootprint << ',' << sample.maximumRSS
                      << ',' << result.observedTextRSS << ',' << result.observedTextFootprint << '\n';
            if (iteration + 1 == warmupRequests) { afterWarmup = sample; }
            if (iteration + 1 >= warmupRequests && sample.currentRSS >= 0) {
                minimumSteadyRSS = minimumSteadyRSS < 0 ? sample.currentRSS : std::min(minimumSteadyRSS, sample.currentRSS);
                maximumSteadyRSS = std::max(maximumSteadyRSS, sample.currentRSS);
            }
            if (iteration >= warmupRequests) {
                firstTokenTotal += firstToken;
                completionTotal += completion;
                observedTextRSSAfterWarmup = std::max(observedTextRSSAfterWarmup, result.observedTextRSS);
                observedTextFootprintAfterWarmup = std::max(observedTextFootprintAfterWarmup, result.observedTextFootprint);
            }
            finalUsage = sample;
        }
        memoryMetrics("after_warmup", afterWarmup);
        memoryMetrics("after_requests", finalUsage);
        std::cout << "rss_growth_after_warmup_bytes=" << (finalUsage.currentRSS >= 0 && afterWarmup.currentRSS >= 0
            ? finalUsage.currentRSS - afterWarmup.currentRSS : -1) << '\n'
                  << "steady_rss_min_bytes=" << minimumSteadyRSS << '\n'
                  << "steady_rss_max_bytes=" << maximumSteadyRSS << '\n'
                  << "observed_text_rss_max_after_warmup_bytes=" << observedTextRSSAfterWarmup << '\n'
                  << "observed_text_physical_footprint_max_after_warmup_bytes=" << observedTextFootprintAfterWarmup << '\n'
                  << "mean_first_token_ms_after_warmup=" << firstTokenTotal / (totalRequests - warmupRequests) << '\n'
                  << "mean_completion_ms_after_warmup=" << completionTotal / (totalRequests - warmupRequests) << '\n';

        const auto unloaded = events.wait(0, Kind::Idle);
        if (unloaded.event.kind != Kind::Idle) {
            throw std::runtime_error("Model did not unload after idling: " + unloaded.event.text);
        }
        memoryMetrics("after_idle_unload", usage());

        const auto reloadStarted = Clock::now();
        const auto reloadId = engine.translate(corpus.front(), bawan::Direction::Automatic);
        const auto reloaded = events.wait(reloadId);
        if (reloaded.event.kind != Kind::Complete || reloaded.event.truncated ||
            reloaded.event.text.empty() || !reloaded.firstText) {
            throw std::runtime_error("Translation after idle unload did not complete normally");
        }
        std::cout << "reload_first_token_ms=" << milliseconds(reloadStarted, *reloaded.firstText) << '\n'
                  << "reload_completion_ms=" << milliseconds(reloadStarted, reloaded.completed) << '\n'
                  << "reload_observed_text_rss_max_bytes=" << reloaded.observedTextRSS << '\n'
                  << "reload_observed_text_physical_footprint_max_bytes=" << reloaded.observedTextFootprint << '\n';
        memoryMetrics("after_reload", usage());
        engine.shutdown();
        std::cout << "profile_complete=true\n";
        return EXIT_SUCCESS;
    } catch (const std::exception & error) {
        std::cerr << "Profile failed: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
