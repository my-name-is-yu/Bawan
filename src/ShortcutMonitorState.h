#pragma once

#include "ShortcutBinding.h"
#include <optional>

namespace bawan {

class ShortcutMonitorState {
public:
    enum class Transition { Start, Stop, Sleep, Wake, Suspend, Resume, EnterConfiguration, LeaveConfiguration };
    enum class Mode { Stopped, Asleep, Suspended, Configuration, Running };

    bool transition(Transition transition) {
        const auto beforeLifecycle = lifecycle_;
        const auto beforeInhibitions = inhibitions_;
        switch (transition) {
            case Transition::Start:
                if (!started()) lifecycle_ = Lifecycle::Awake;
                break;
            case Transition::Stop: lifecycle_ = Lifecycle::Stopped; break;
            case Transition::Sleep:
                if (started()) lifecycle_ = Lifecycle::Asleep;
                break;
            case Transition::Wake:
                if (started()) lifecycle_ = Lifecycle::Awake;
                break;
            case Transition::Suspend: inhibitions_ |= Suspended; break;
            case Transition::Resume: inhibitions_ &= ~Suspended; break;
            case Transition::EnterConfiguration: inhibitions_ |= Configuration; break;
            case Transition::LeaveConfiguration: inhibitions_ &= ~Configuration; break;
        }
        return beforeLifecycle != lifecycle_ || beforeInhibitions != inhibitions_;
    }

    bool started() const { return lifecycle_ != Lifecycle::Stopped; }
    bool awake() const { return lifecycle_ == Lifecycle::Awake; }
    Mode mode() const {
        if (!started()) return Mode::Stopped;
        if (!awake()) return Mode::Asleep;
        if (suspended()) return Mode::Suspended;
        if (configurationActive()) return Mode::Configuration;
        return Mode::Running;
    }
    bool running() const { return mode() == Mode::Running; }
    // Settings still needs live permission/tap availability while actions are bypassed.
    bool observing() const { return running() || mode() == Mode::Configuration; }
    bool suspended() const { return inhibitions_ & Suspended; }
    bool configurationActive() const { return inhibitions_ & Configuration; }

private:
    enum class Lifecycle { Stopped, Awake, Asleep };
    enum Inhibition : unsigned { Suspended = 1, Configuration = 2 };
    Lifecycle lifecycle_ = Lifecycle::Stopped;
    unsigned inhibitions_ = 0;
};

// Ownership outlives gesture configuration: an intercepted down owns its repeats
// and release even when the binding or monitoring mode changes while held.
class ShortcutKeyOwnership {
public:
    struct Result {
        bool consumed = false;
        bool drainingDown = false;
        bool copyReleased = false;
        bool copyInterrupted = false;
    };

    Result handle(ShortcutEvent::Kind kind, std::uint16_t key) {
        Result result;
        if (kind == ShortcutEvent::Kind::FlagsChanged) return result;
        if (key < keys_.size()) {
            result.consumed = keys_[key] != Ownership::None;
            result.drainingDown = kind == ShortcutEvent::Kind::KeyDown && keys_[key] == Ownership::Draining;
            if (kind == ShortcutEvent::Kind::KeyUp) keys_[key] = Ownership::None;
        }
        if (copyReleaseKey_) {
            result.copyReleased = kind == ShortcutEvent::Kind::KeyUp && key == *copyReleaseKey_;
            result.copyInterrupted = kind == ShortcutEvent::Kind::KeyDown && key != *copyReleaseKey_;
            if (result.copyReleased || result.copyInterrupted) cancelCopy();
        }
        return result;
    }

    void capture(std::uint16_t key) {
        if (key < keys_.size()) keys_[key] = Ownership::Gesture;
    }
    void reconfigure() {
        for (auto &key : keys_) if (key == Ownership::Gesture) key = Ownership::Draining;
        cancelCopy();
    }
    bool draining() const {
        for (auto key : keys_) if (key != Ownership::None) return true;
        return false;
    }
    template<typename IsDown> void reconcile(IsDown isDown) {
        for (unsigned key = 0; key < keys_.size(); ++key) {
            if (keys_[key] != Ownership::None && !isDown(key)) {
                keys_[key] = Ownership::None;
                if (copyReleaseKey_ == key) cancelCopy();
            }
        }
    }
    void awaitCopyRelease(std::uint16_t key) { copyReleaseKey_ = key; }
    void cancelCopy() { copyReleaseKey_.reset(); }
    void reset() {
        keys_.fill(Ownership::None);
        cancelCopy();
    }

private:
    enum class Ownership { None, Gesture, Draining };
    std::array<Ownership, 128> keys_{};
    std::optional<std::uint16_t> copyReleaseKey_;
};

}
