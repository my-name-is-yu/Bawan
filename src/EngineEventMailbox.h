#pragma once

#include "TranslationEngine.h"
#include <mutex>
#include <utility>
#include <vector>

namespace lore {
// Worker-to-UI handoff. Text contains a full snapshot, not a delta, so only
// the newest consecutive snapshot for a request needs to wait for the UI.
// Lifecycle/terminal events remain ordered and are never coalesced.
class EngineEventMailbox final {
public:
    // True means the caller must schedule one drain on the UI queue.
    bool push(EngineEvent event) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!events_.empty() && event.kind == EngineEvent::Kind::Text &&
            events_.back().kind == EngineEvent::Kind::Text &&
            events_.back().requestId == event.requestId) {
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
} // namespace lore
