#include "TranslationSession.h"

#include <cstdlib>
#include <iostream>
#include <string_view>
#include <utility>

namespace {

using bawan::Direction;
using Session = bawan::TranslationSession;
constexpr auto ToJapanese = Direction::EnglishToJapanese;
constexpr auto ToEnglish = Direction::JapaneseToEnglish;

void require(bool condition, std::string_view message) {
    if (!condition) {
        std::cerr << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

template <class... Types>
void expect(const Session::Effects & effects, std::string_view message) {
    require(effects.size() == sizeof...(Types), message);
    std::size_t i = 0;
    require((std::holds_alternative<Types>(effects[i++]) && ...), message);
}

Session::Submit manual(std::string text, Direction direction = ToJapanese) {
    return {{std::move(text), direction}, Session::Manual{}};
}

Session::Submit selection(std::string text) {
    return {{std::move(text), Direction::Automatic}, Session::Selection{}};
}

Session::Submit trial(Session::TrialAttempt attempt) {
    return {{"Practice", Direction::Automatic}, Session::Trial{attempt}};
}

void latestQueuedRequestWins() {
    Session session;
    expect<Session::ClearOutput, Session::Status>(
        session.reduce(manual("First")), "Queuing clears the old output and status");
    (void)session.reduce(manual(u8"次の文", ToEnglish));
    require(std::holds_alternative<Session::Queued>(session.state()), "Unverified work stays queued");
    expect<>(session.reduce(Session::WarmUpRequested{}), "Queued work waits for model verification");
    expect<>(session.reduce(Session::ModelPreparing{}), "Starting verification preserves work already waiting for it");
    const auto effects = session.reduce(Session::ModelReady{});
    expect<Session::SubmitRequest>(effects, "The pending request takes priority over prewarming");
    const auto & request = std::get<Session::SubmitRequest>(effects.front());
    require(request.source.text == u8"次の文" && request.source.direction == ToEnglish,
        "Readiness must submit the latest text with its direction");
    require(std::holds_alternative<Session::Manual>(std::get<Session::Running>(session.state()).origin),
        "Starting a queued request preserves its origin");
    expect<>(session.reduce(Session::ModelReady{}), "Repeated readiness must not replay a request");
}

void warmupAndCancellation() {
    Session session;
    expect<>(session.reduce(Session::WarmUpRequested{}), "Prewarming must wait for verification");
    expect<>(session.reduce(Session::WarmUpRequested{}), "Pending prewarm requests coalesce");
    expect<Session::WarmUp>(session.reduce(Session::ModelReady{}), "Verification releases the deferred warmup");
    expect<>(session.reduce(Session::ModelReady{}), "Deferred warmup is consumed only once");
    expect<Session::WarmUp>(session.reduce(Session::WarmUpRequested{}), "A verified idle engine can be prewarmed");
    expect<Session::CancelEngine>(session.reduce(Session::Cancel{}), "Idle cancellation also stops engine warmup");
    (void)session.reduce(Session::ModelPreparing{});
    (void)session.reduce(manual("Queued"));
    (void)session.reduce(Session::WarmUpRequested{});
    const auto cancelled = session.reduce(Session::Cancel{});
    expect<Session::Status>(cancelled, "Cancel queued work without creating an engine");
    require(std::get<Session::Status>(cancelled.front()) == Session::Status::Cancelled,
        "Queued cancellation reports a cancellation outcome");
    expect<>(session.reduce(Session::ModelReady{}), "Cancel drops both queued work and deferred warmup");
    require(std::holds_alternative<Session::Idle>(session.state()), "Cancel leaves no active request");
}

void replacementAndStaleCallbacks() {
    Session session;
    (void)session.reduce(Session::ModelReady{});
    auto effects = session.reduce(manual("Old"));
    expect<Session::ClearOutput, Session::Status, Session::SubmitRequest>(effects, "A fresh submission resets output");
    const auto old = std::get<Session::SubmitRequest>(effects.back()).requestId;
    effects = session.reduce(selection("New"));
    expect<Session::CancelEngine, Session::ClearOutput, Session::Status, Session::SubmitRequest>(effects,
        "Replacement must cancel the old engine work before submitting the new request");
    const auto current = std::get<Session::SubmitRequest>(effects.back()).requestId;
    require(!(old == current), "Replacement must use a fresh request ID");
    require(std::holds_alternative<Session::Selection>(std::get<Session::Running>(session.state()).origin),
        "The running request remembers its selection origin");
    expect<>(session.reduce(Session::EngineEvent{old, Session::Progress{{"Old partial", ToJapanese}}}),
        "Stale progress must not reach the translator");
    expect<>(session.reduce(Session::EngineEvent{old, Session::Complete{{"Old result", ToJapanese}, false}}),
        "Stale completion must not finish the replacement");
    expect<>(session.reduce(Session::EngineEvent{old, Session::EngineError{"Old error"}}),
        "Stale errors must not reach the translator");
    effects = session.reduce(Session::EngineEvent{current, Session::Progress{{u8"新しい", ToJapanese}}});
    expect<Session::Output>(effects, "Matching progress updates the translator");
    const auto & partial = std::get<Session::Output>(effects.front());
    require(partial.text == u8"新しい" && partial.direction == ToJapanese, "Progress preserves text and direction");
    require(std::holds_alternative<Session::Running>(session.state()), "Progress is not terminal");
    effects = session.reduce(Session::EngineEvent{current, Session::Complete{{u8"新しい文", ToJapanese}, true}});
    expect<Session::Output, Session::Status>(effects, "Completion publishes final output before its status");
    require(std::get<Session::Output>(effects.front()).text == u8"新しい文" &&
        std::get<Session::Status>(effects.back()) == Session::Status::Truncated,
        "A truncated normal result still displays its text with a warning");
    require(std::holds_alternative<Session::Idle>(session.state()), "Completion returns to idle");
    expect<>(session.reduce(Session::EngineEvent{current, Session::Cancelled{}}), "Duplicate terminal events are stale");
}

void requestFailuresDoNotInvalidateTheModel() {
    Session session;
    (void)session.reduce(Session::ModelReady{});
    auto start = [&session] {
        return std::get<Session::SubmitRequest>(session.reduce(manual("Hello")).back()).requestId;
    };
    auto effects = session.reduce(Session::EngineEvent{start(), Session::EngineError{"Inference failed"}});
    expect<Session::TranslationError>(effects, "A current engine error reports a translation error");
    require(std::get<Session::TranslationError>(effects.front()).message == "Inference failed" &&
        std::holds_alternative<Session::Idle>(session.state()), "An engine error preserves its message and ends the request");
    effects = session.reduce(Session::EngineEvent{start(), Session::Cancelled{}});
    expect<Session::Status>(effects, "A current engine cancellation emits only a status");
    require(std::get<Session::Status>(effects.front()) == Session::Status::Cancelled &&
        std::holds_alternative<Session::Idle>(session.state()), "Engine cancellation is terminal");
    const auto requestId = start();
    expect<Session::CancelEngine, Session::Status>(session.reduce(Session::Cancel{}), "Explicit cancellation stops inference");
    expect<>(session.reduce(Session::EngineEvent{requestId, Session::Progress{{"Late text", ToJapanese}}}),
        "Late progress cannot overwrite output after explicit cancellation");
    expect<Session::Output, Session::Status>(
        session.reduce(Session::EngineEvent{start(), Session::Complete{{"New result", ToJapanese}, false}}),
        "A fresh request can succeed without re-verifying the model");
}

void modelFailureDropsQueuedWorkAndWarmup() {
    Session session;
    (void)session.reduce(selection("Discarded selection"));
    (void)session.reduce(Session::WarmUpRequested{});
    const auto failed = session.reduce(Session::ModelFailed{"Verification failed"});
    expect<Session::ModelError>(failed, "Verification failure reports a model error, not a translation error");
    require(std::get<Session::ModelError>(failed.front()).message == "Verification failed", "Keep the model error message");
    require(std::holds_alternative<Session::Idle>(session.state()), "Verification failure drops queued work");
    expect<>(session.reduce(manual("While failed")), "Failed preparation rejects new work until a retry");
    (void)session.reduce(Session::ModelPreparing{});
    expect<>(session.reduce(Session::ModelReady{}), "Retry cannot resurrect dropped requests or warmup");
    const auto running = session.reduce(manual("Before revalidation"));
    const auto stale = std::get<Session::SubmitRequest>(running.back()).requestId;
    expect<Session::CancelEngine>(session.reduce(Session::ModelPreparing{}), "Revalidation stops active inference");
    (void)session.reduce(manual("After revalidation"));
    const auto next = session.reduce(Session::ModelReady{});
    require(!(std::get<Session::SubmitRequest>(next.back()).requestId == stale), "Retry must not reuse a request ID");
    expect<>(session.reduce(Session::EngineEvent{stale, Session::EngineError{"Late failure"}}),
        "The old engine's request is stale after revalidation");
}

void trialInvalidationPreservesAQueuedSelection() {
    Session session{Session::TranslatorAccess::AwaitingOnboarding};
    constexpr Session::TrialAttempt attempt{7};
    (void)session.reduce(selection("External selection"));
    expect<>(session.reduce(trial(attempt)), "A queued trial does not clear translator output");
    expect<>(session.reduce(trial(attempt)), "Duplicate trial submission is a no-op");
    expect<>(session.reduce(Session::TrialInvalidated{{6}}), "An old invalidation cannot affect the current trial");
    const auto ready = session.reduce(Session::ModelReady{});
    expect<Session::SubmitRequest>(ready, "Verification starts the trial before the held selection");
    const auto & request = std::get<Session::SubmitRequest>(ready.front());
    require(request.source.text == "Practice", "Verification must start the trial text");
    expect<>(session.reduce(Session::EngineEvent{request.requestId, Session::Progress{{"Partial", ToJapanese}}}),
        "Trial progress must not write to the translator");
    expect<Session::CancelEngine, Session::TrialDiscarded>(
        session.reduce(Session::TrialInvalidated{attempt}), "Invalidating a running trial stops only that trial");
    expect<>(session.reduce(Session::EngineEvent{request.requestId, Session::Complete{{"Late practice", ToJapanese}, false}}),
        "Late completion cannot revive an invalidated trial");
    expect<>(session.reduce(Session::ModelReady{}), "A verified model cannot bypass onboarding");
    const auto opened = session.reduce(Session::OpenTranslator{});
    expect<Session::SubmitRequest>(opened, "Opening the translator resumes the original selection");
    require(std::get<Session::SubmitRequest>(opened.front()).source.text == "External selection",
        "A trial must not erase the external selection");
}

void onlyNonemptyUntruncatedTrialCompletionSucceeds() {
    using Outcome = Session::EngineEvent::Update;
    const std::pair<Outcome, bool> cases[] = {
        {Session::Complete{{u8"練習", ToJapanese}, false}, true},
        {Session::Complete{{"Truncated", ToJapanese}, true}, false},
        {Session::Complete{{"", ToJapanese}, false}, false},
        {Session::Cancelled{}, false},
        {Session::EngineError{"Failed"}, false},
    };
    for (const auto & [outcome, succeeds] : cases) {
        Session session{Session::TranslatorAccess::AwaitingOnboarding};
        constexpr Session::TrialAttempt attempt{11};
        (void)session.reduce(Session::ModelReady{});
        const auto started = session.reduce(trial(attempt));
        expect<Session::SubmitRequest>(started, "Trial submission must not reset the translator");
        const auto id = std::get<Session::SubmitRequest>(started.front()).requestId;
        const auto finished = session.reduce(Session::EngineEvent{id, outcome});
        expect<Session::TrialFinished>(finished, "Trial completion must not emit translator output or status");
        const auto & result = std::get<Session::TrialFinished>(finished.front());
        require(result.attempt == attempt && result.output.has_value() == succeeds,
            "Only a complete nonempty trial produces usable output");
        if (succeeds) {
            require(result.output->text == u8"練習" && result.output->direction == ToJapanese,
                "A successful trial keeps its exact output and direction");
        }
        require(std::holds_alternative<Session::Idle>(session.state()), "A finished trial releases the request");
        expect<>(session.reduce(Session::EngineEvent{id, outcome}), "Repeating completion must not finish a trial twice");
    }
}

void invalidatingQueuedTrialAndSkippingOnboarding() {
    constexpr Session::TrialAttempt attempt{5};
    Session session{Session::TranslatorAccess::AwaitingOnboarding};
    (void)session.reduce(selection("Original"));
    (void)session.reduce(trial(attempt));
    expect<Session::TrialDiscarded>(session.reduce(Session::TrialInvalidated{attempt}),
        "A queued trial can be invalidated without cancelling engine work");
    expect<>(session.reduce(Session::ModelReady{}), "Readiness must not start an invalidated trial or bypass onboarding");
    const auto effects = session.reduce(Session::OpenTranslator{});
    expect<Session::SubmitRequest>(effects, "The queued selection survives invalidation while waiting for the model");
    require(std::get<Session::SubmitRequest>(effects.front()).source.text == "Original", "Resume the original selection");

    Session skipped{Session::TranslatorAccess::AwaitingOnboarding};
    (void)skipped.reduce(selection("Held"));
    (void)skipped.reduce(Session::ModelReady{});
    (void)skipped.reduce(trial(attempt));
    expect<Session::CancelEngine, Session::TrialDiscarded, Session::SubmitRequest>(
        skipped.reduce(Session::OpenTranslator{}), "Skipping cancels practice before starting the held selection");
}

void acceptingATrialDiscardsTheHeldSelection() {
    Session session{Session::TranslatorAccess::AwaitingOnboarding};
    constexpr Session::TrialAttempt attempt{23};
    (void)session.reduce(selection("Prior selection"));
    (void)session.reduce(Session::ModelReady{});
    const auto started = session.reduce(trial(attempt));
    const auto id = std::get<Session::SubmitRequest>(started.front()).requestId;
    const auto finished = session.reduce(Session::EngineEvent{id, Session::Complete{{"Practice result", ToJapanese}, false}});
    expect<Session::TrialFinished>(finished, "A successful trial must not submit the held selection");
    require(std::holds_alternative<Session::Queued>(session.state()), "Hold the prior selection until the user decides");
    expect<>(session.reduce(Session::OpenTranslator{Session::PendingSelection::Discard}),
        "Accepting the practice result discards the prior selection without another engine request");
    require(std::holds_alternative<Session::Idle>(session.state()), "Discarding the prior selection leaves no work");
}

void modelFailureDiscardsTheTrialAndHeldSelection() {
    Session session{Session::TranslatorAccess::AwaitingOnboarding};
    constexpr Session::TrialAttempt attempt{28};
    (void)session.reduce(selection("Selection"));
    (void)session.reduce(trial(attempt));
    const auto failure = session.reduce(Session::ModelFailed{"Verification failed"});
    expect<Session::TrialDiscarded, Session::ModelError>(failure, "Model failure discards the queued trial");
    require(std::get<Session::TrialDiscarded>(failure.front()).attempt == attempt, "Discard the matching trial attempt");
    const auto rejected = session.reduce(trial({29}));
    expect<Session::TrialFinished>(rejected, "A trial submitted after verification failure cannot start");
    require(!std::get<Session::TrialFinished>(rejected.front()).output, "A rejected trial cannot report a result");
    expect<>(session.reduce(Session::OpenTranslator{}), "Opening the translator does not restore discarded work");
    expect<>(session.reduce(Session::ModelReady{}), "Later readiness cannot resurrect the trial or the held selection");
}

}

int main() {
    latestQueuedRequestWins();
    warmupAndCancellation();
    replacementAndStaleCallbacks();
    requestFailuresDoNotInvalidateTheModel();
    modelFailureDropsQueuedWorkAndWarmup();
    trialInvalidationPreservesAQueuedSelection();
    onlyNonemptyUntruncatedTrialCompletionSucceeds();
    invalidatingQueuedTrialAndSkippingOnboarding();
    acceptingATrialDiscardsTheHeldSelection();
    modelFailureDiscardsTheTrialAndHeldSelection();
}
