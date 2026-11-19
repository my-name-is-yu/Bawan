#pragma once

#include "TranslationEngine.h"

#include <cstdint>
#include <optional>
#include <string>
#include <variant>
#include <vector>

namespace bawan {

class TranslationSession final {
public:
    struct RequestId {
        std::uint64_t value;
        bool operator==(RequestId other) const { return value == other.value; }
    };
    struct TrialAttempt {
        std::uint64_t value;
        bool operator==(TrialAttempt other) const { return value == other.value; }
    };

    struct Manual {};
    struct Selection {};
    struct Trial { TrialAttempt attempt; };
    using Origin = std::variant<Manual, Selection, Trial>;

    struct Source { std::string text; Direction direction; };
    struct Idle {};
    struct Queued { Source source; Origin origin; };
    struct Running { RequestId requestId; Origin origin; };
    using State = std::variant<Idle, Queued, Running>;

    enum class TranslatorAccess { AwaitingOnboarding, Open };
    enum class PendingSelection { Resume, Discard };
    struct OpenTranslator { PendingSelection pending = PendingSelection::Resume; };
    struct ModelPreparing {};
    struct ModelReady {};
    struct ModelFailed { std::string message; };
    struct Submit { Source source; Origin origin; };
    struct Cancel {};
    struct WarmUpRequested {};
    struct TrialInvalidated { TrialAttempt attempt; };

    struct Output { std::string text; Direction direction; };
    struct Progress { Output output; };
    struct Complete { Output output; bool truncated; };
    struct Cancelled {};
    struct EngineError { std::string message; };
    struct EngineEvent {
        using Update = std::variant<Progress, Complete, Cancelled, EngineError>;
        RequestId requestId;
        Update update;
    };
    using Event = std::variant<OpenTranslator, ModelPreparing, ModelReady, ModelFailed, Submit,
        Cancel, WarmUpRequested, TrialInvalidated, EngineEvent>;

    struct SubmitRequest { RequestId requestId; Source source; };
    struct CancelEngine {};
    struct WarmUp {};
    struct ClearOutput {};
    enum class Status { Clear, Cancelled, Truncated };
    struct TranslationError { std::string message; };
    struct ModelError { std::string message; };
    struct TrialFinished { TrialAttempt attempt; std::optional<Output> output; };
    struct TrialDiscarded { TrialAttempt attempt; };
    using Effect = std::variant<SubmitRequest, CancelEngine, WarmUp, ClearOutput, Output, Status,
        TranslationError, ModelError, TrialFinished, TrialDiscarded>;
    using Effects = std::vector<Effect>;

    explicit TranslationSession(TranslatorAccess access = TranslatorAccess::Open) : access_(access) {}

    const State & state() const { return state_; }
    [[nodiscard]] Effects reduce(Event event);

private:
    enum class ModelAvailability { Preparing, Ready, Failed };

    void advance(Effects & effects);
    const Trial * activeTrial() const;
    void interrupt(Effects & effects);
    void resetWork(Effects & effects);
    void restoreSelection();
    void submit(Submit event, Effects & effects);
    void handleEngineEvent(EngineEvent event, Effects & effects);

    State state_;
    TranslatorAccess access_;
    ModelAvailability model_ = ModelAvailability::Preparing;
    std::optional<Source> suspendedSelection_;
    bool warmUpPending_ = false;
    std::uint64_t lastRequestId_ = 0;
};

}
