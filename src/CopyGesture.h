#pragma once

#include <cstdint>

namespace lore {

// A small state machine independent of AppKit so timing and repeat handling can
// be exercised without a running event tap.
class CopyGesture {
public:
    enum class Result { None, FirstCopy, DoubleCopy };
    struct Event {
        bool down;
        std::uint16_t key;
        bool command;
        bool otherModifier;
        bool repeat;
        std::int64_t application;
        std::uint64_t timeNanoseconds;
    };

    Result handle(const Event& event);
    void reset();

private:
    bool cDown_ = false;
    bool armed_ = false;
    std::int64_t application_ = 0;
    std::uint64_t firstTime_ = 0;
};

} // namespace lore
