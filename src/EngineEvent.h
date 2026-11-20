#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <variant>

namespace bawan {

enum class Direction { Automatic, EnglishToJapanese, JapaneseToEnglish };

namespace engine {

using RequestId = std::uint64_t;

template <typename... Handlers>
struct Visitor : Handlers... { using Handlers::operator()...; };
template <typename... Handlers>
Visitor(Handlers...) -> Visitor<Handlers...>;

struct Loading {};
struct Ready {};
struct Idle {};
struct LoadCancelled {};
struct Failed { std::string message; };
using Lifecycle = std::variant<Loading, Ready, Idle, LoadCancelled, Failed>;

struct Progress {
    RequestId requestId;
    std::string textSoFar;
    Direction direction;
};

struct Complete {
    std::string text;
    bool truncated;
    Direction direction;
};

struct Cancelled {};
struct Error { std::string message; };
using Outcome = std::variant<Complete, Cancelled, Error>;

struct Finished {
    RequestId requestId;
    Outcome outcome;
};

}

using EngineEvent = std::variant<engine::Lifecycle, engine::Progress, engine::Finished>;

namespace engine {

struct EventDescription {
    const char *name;
    const char *probeValue = nullptr;
    std::optional<RequestId> requestId = std::nullopt;
};

inline EventDescription describe(const EngineEvent &event) noexcept {
    return std::visit(Visitor{
        [](const Lifecycle &state) {
            return std::visit(Visitor{
                [](Loading) { return EventDescription{"Loading"}; },
                [](Ready) { return EventDescription{"Ready"}; },
                [](Idle) { return EventDescription{"Idle", "idle"}; },
                [](LoadCancelled) { return EventDescription{"LoadCancelled", "error"}; },
                [](const Failed &) { return EventDescription{"Failed", "error"}; },
            }, state);
        },
        [](const Progress &progress) { return EventDescription{"Progress", nullptr, progress.requestId}; },
        [](const Finished &finished) {
            auto description = std::visit(Visitor{
                [](const Complete &) { return EventDescription{"Complete", "complete"}; },
                [](Cancelled) { return EventDescription{"Cancelled", "error"}; },
                [](const Error &) { return EventDescription{"Error", "error"}; },
            }, finished.outcome);
            description.requestId = finished.requestId;
            return description;
        },
    }, event);
}

}

}
