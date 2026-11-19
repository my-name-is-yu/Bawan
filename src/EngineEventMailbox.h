#pragma once

#include "EngineEvent.h"
#include <mutex>
#include <utility>
#include <vector>

namespace bawan {
// Worker-to-UI handoff. Progress contains a full snapshot, not a delta, so only
// the newest consecutive snapshot for a request needs to wait for the UI.
// Lifecycle/terminal events remain ordered and are never coalesced.
class EngineEventMailbox final {
public:
    // True means the caller must schedule one drain on the UI queue.
    bool push(EngineEvent event) {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto *progress = std::get_if<engine::Progress>(&event);
        const auto *previous = events_.empty() ? nullptr : std::get_if<engine::Progress>(&events_.back());
        if (progress && previous && previous->requestId == progress->requestId) {
            events_.back() = std::move(event);
        } else {
            events_.push_back(std::move(event));
        }
        if (scheduled_) return false;
        scheduled_ = true;
        return true;
    }

    std::vector<EngineEvent> drain() {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<EngineEvent> result;
        result.swap(events_);
        scheduled_ = false;
        return result;
    }
private:
    std::mutex mutex_;
    std::vector<EngineEvent> events_;
    bool scheduled_ = false;
};
}
