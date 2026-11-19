#pragma once

#include <cstdint>
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

}
