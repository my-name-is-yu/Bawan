#pragma once

#include "EngineEvent.h"

#include <optional>
#include <string>
#include <variant>
#include <vector>

namespace bawan {

class TranslationSession final {
public:
    using RequestId = engine::RequestId;
    struct Manual {};
    struct Selection {};
    struct Trial {};
    using Origin = std::variant<Manual, Selection, Trial>;

    struct Source { std::string text; Direction direction; };
    enum class Phase { Idle, Queued, Starting, Running };
    enum class ModelAvailability { Pending, Available, Failed };
    enum class TranslatorAccess { AwaitingOnboarding, Open };
    enum class PendingSelection { Resume, Discard };
    struct OpenTranslator { PendingSelection pending = PendingSelection::Resume; };
    struct Submit { Source source; Origin origin; };
    struct Cancel {};
    struct WarmUpRequested {};
    struct TrialInvalidated {};
    using Event = std::variant<OpenTranslator, Submit, Cancel, WarmUpRequested, TrialInvalidated, EngineEvent>;

    struct SubmitRequest { Source source; };
    struct CancelEngine {};
    struct WarmUp {};
    struct ClearOutput {};
    struct Output { std::string text; Direction direction; };
    enum class Status { Clear, Cancelled, Truncated };
    struct TranslationError { std::string message; };
    struct TrialFinished { std::optional<Output> output; };
    struct TrialDiscarded {};
    using Effect = std::variant<SubmitRequest, CancelEngine, WarmUp, ClearOutput, Output, Status,
        TranslationError, TrialFinished, TrialDiscarded>;
    using Effects = std::vector<Effect>;

    explicit TranslationSession(TranslatorAccess access = TranslatorAccess::Open);

    Phase phase() const;
    TranslatorAccess access() const;
    bool busy() const { return phase() != Phase::Idle; }
    std::optional<RequestId> activeRequestId() const;
    [[nodiscard]] Effects reduce(Event event, ModelAvailability model);
    [[nodiscard]] Effects synchronizeModel(ModelAvailability model);
    [[nodiscard]] Effects resolveSubmission(std::optional<RequestId> id);

private:
    struct Idle {};
    struct DeferredWarmUp {};
    template <class O> struct Queued { Source source; O origin; };
    template <class O> struct Starting { O origin; };
    template <class O> struct Running { RequestId requestId; O origin; };
    template <class O> using Work = std::variant<Idle, DeferredWarmUp, Queued<O>, Starting<O>, Running<O>>;

    struct Onboarding { std::optional<Source> selection; Work<Trial> work; };
    struct Translator { Work<Origin> work; };

    template <class Self, class F> static decltype(auto) withWork(Self & self, F f);
    template <class O> static Phase phaseOf(const Work<O> & work);
    template <class O> static std::optional<RequestId> requestIdOf(const Work<O> & work);
    template <class O> static void startRequest(Work<O> & work, Effects & effects);
    template <class O> static void acceptRequestId(Work<O> & work, RequestId id);
    template <class O> static bool isTrial(const Work<O> & work);
    template <class O> static void interrupt(Work<O> & work, Effects & effects);
    bool practicing() const;
    void openTranslator(OpenTranslator event, ModelAvailability model, Effects & effects);
    void drainPendingWork(Effects & effects);
    void resetWork(ModelAvailability model, Effects & effects);
    void submit(Submit event, ModelAvailability model, Effects & effects);
    void receiveEngineEvent(EngineEvent event, Effects & effects);

    std::variant<Onboarding, Translator> surface_ = Translator{};
};

}
