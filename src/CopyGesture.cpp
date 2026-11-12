#include "CopyGesture.h"

namespace lore {

CopyGesture::Result CopyGesture::handle(const Event& event) {
    constexpr std::uint16_t cKey = 8; // kVK_ANSI_C (physical C key)
    constexpr std::uint64_t doubleCopyInterval = 400'000'000;

    if (event.application != application_) {
        reset();
        application_ = event.application;
    }
    if (!event.down) {
        if (event.key == cKey) cDown_ = false;
        return Result::None;
    }
    if (event.key != cKey || !event.command || event.otherModifier || event.repeat) {
        armed_ = false;
        if (event.key == cKey) cDown_ = true;
        return Result::None;
    }
    if (cDown_) return Result::None;
    cDown_ = true;

    if (armed_ && event.timeNanoseconds >= firstTime_ &&
        event.timeNanoseconds - firstTime_ <= doubleCopyInterval) {
        armed_ = false;
        return Result::DoubleCopy;
    }
    armed_ = true;
    firstTime_ = event.timeNanoseconds;
    return Result::FirstCopy;
}

void CopyGesture::reset() {
    cDown_ = false;
    armed_ = false;
    application_ = 0;
    firstTime_ = 0;
}

} // namespace lore
