#pragma once

#include "EngineEvent.h"

namespace bawan::test {

template <typename State>
const State *lifecycle(const EngineEvent &event) {
    const auto *state = std::get_if<engine::Lifecycle>(&event);
    return state ? std::get_if<State>(state) : nullptr;
}

template <typename Result>
const Result *outcome(const EngineEvent &event) {
    const auto *finished = std::get_if<engine::Finished>(&event);
    return finished ? std::get_if<Result>(&finished->outcome) : nullptr;
}

}
