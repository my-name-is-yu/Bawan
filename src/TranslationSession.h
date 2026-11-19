#pragma once

#include "EngineEvent.h"

#include <cstdint>
#include <optional>
#include <string>
#include <variant>
#include <vector>

namespace bawan {

class TranslationSession final {
public:
    using RequestId = engine::RequestId;
    struct TrialAttempt {
        std::uint64_t value;
        bool operator==(TrialAttempt other) const { return value == other.value; }
    };

    struct Manual {};
    struct Selection {};
    struct Trial { TrialAttempt attempt; };
    using Origin = std::variant<Manual, Selection, Trial>;

    struct Source { std::string text; Direction direction; };
    enum class Phase { Idle, Queued, Starting, Running };
    enum class TranslatorAccess { AwaitingOnboarding, Open };
    enum class PendingSelection { Resume, Discard };
    struct OpenTranslator { PendingSelection pending = PendingSelection::Resume; };
    struct ModelPreparing {};
    struct ModelReady {};
    struct ModelFailed { std::string message; };
    struct Submit { Source source; Origin origin; };
    struct RequestStarted { RequestId requestId; };
    struct Cancel {};
    struct WarmUpRequested {};
    struct TrialInvalidated { TrialAttempt attempt; };
    using Event = std::variant<OpenTranslator, ModelPreparing, ModelReady, ModelFailed, Submit, RequestStarted,
        Cancel, WarmUpRequested, TrialInvalidated, EngineEvent>;

    struct SubmitRequest { Source source; };
    struct CancelEngine {};
    struct WarmUp {};
    struct ClearOutput {};
    struct Output { std::string text; Direction direction; };
    enum class Status { Clear, Cancelled, Truncated };
    struct TranslationError { std::string message; };
    struct ModelError { std::string message; };
    struct TrialFinished { TrialAttempt attempt; std::optional<Output> output; };
    struct TrialDiscarded { TrialAttempt attempt; };
    using Effect = std::variant<SubmitRequest, CancelEngine, WarmUp, ClearOutput, Output, Status,
        TranslationError, ModelError, TrialFinished, TrialDiscarded>;
    using Effects = std::vector<Effect>;

    explicit TranslationSession(TranslatorAccess access = TranslatorAccess::Open);

    Phase phase() const;
    bool busy() const { return phase() != Phase::Idle; }
    std::optional<RequestId> activeRequestId() const;
    std::optional<TrialAttempt> trialAttempt() const;
    [[nodiscard]] Effects reduce(Event event);

private:
    struct Idle {};
    template <class O> struct Queued { Source source; O origin; };
    template <class O> struct Starting { O origin; };
    template <class O> struct Running { RequestId requestId; O origin; };
    template <class O> using Work = std::variant<Idle, Queued<O>, Starting<O>, Running<O>>;

    using TranslatorOrigin = std::variant<Manual, Selection>;
    struct Onboarding { std::optional<Source> selection; Work<Trial> work; };
    struct Translator { Work<TranslatorOrigin> work; };

    enum class WarmUpPlan { None, Pending };
    struct Preparing { WarmUpPlan warmUp = WarmUpPlan::None; };
    struct Ready {};
    struct Failed {};
    struct State {
        std::variant<Preparing, Ready, Failed> model = Preparing{};
        std::variant<Onboarding, Translator> surface = Translator{};
    };

    template <class Self, class F> static decltype(auto) withWork(Self & self, F f);
    template <class O> static Phase phaseOf(const Work<O> & work);
    template <class O> static std::optional<RequestId> requestIdOf(const Work<O> & work);
    template <class O> static void startRequest(Work<O> & work, Effects & effects);
    template <class O> static void acceptRequestId(Work<O> & work, RequestId id);
    template <class O> static bool interrupt(Work<O> & work, Effects & effects);
    void openTranslator(OpenTranslator event, Effects & effects);
    void modelReady(Effects & effects);
    void resetWork(Effects & effects);
    void submit(Submit event, Effects & effects);
    void receiveEngineEvent(EngineEvent event, Effects & effects);

    State state_;
};

}
