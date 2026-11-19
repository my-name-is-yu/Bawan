#include "TranslationSession.h"

#include <cstdlib>
#include <iostream>
#include <string_view>
#include <utility>

namespace {

using bawan::Direction;
using bawan::EngineEvent;
using Session = bawan::TranslationSession;
using namespace bawan::engine;
using Phase = Session::Phase;
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

void requestStarted(Session & session, Session::RequestId id) {
    require(session.phase() == Phase::Starting && !session.activeRequestId(),
        "The reducer must wait for the engine-assigned ID after emitting a submit");
    expect<>(session.reduce(Session::RequestStarted{id}), "Acknowledging an engine ID emits no further effects");
    require(session.phase() == Phase::Running && session.activeRequestId() == id, "Track the engine-assigned ID");
}

void latestQueuedRequestWins() {
    Session session;
    expect<Session::ClearOutput>(session.reduce(manual("First")), "Queuing clears stale output");
    (void)session.reduce(manual(u8"次の文", ToEnglish));
    require(session.phase() == Phase::Queued, "Unverified work stays queued");
    expect<>(session.reduce(Session::WarmUpRequested{}), "Warmup waits for verification");
    expect<>(session.reduce(Session::ModelPreparing{}), "Starting verification preserves queued work");
    const auto effects = session.reduce(Session::ModelReady{});
    expect<Session::Status, Session::SubmitRequest>(effects, "The pending request takes priority over prewarming");
    const auto & source = std::get<Session::SubmitRequest>(effects.back()).source;
    require(source.text == u8"次の文" && source.direction == ToEnglish, "Readiness submits the latest text and direction");
    requestStarted(session, 61);
    expect<>(session.reduce(Session::ModelReady{}), "Repeated readiness must not replay a request");
}

void warmupAndCancellation() {
    Session session;
    expect<>(session.reduce(Session::WarmUpRequested{}), "Prewarming waits for verification");
    expect<>(session.reduce(Session::WarmUpRequested{}), "Pending prewarm requests coalesce");
    expect<Session::WarmUp>(session.reduce(Session::ModelReady{}), "Verification releases the deferred warmup");
    expect<>(session.reduce(Session::ModelReady{}), "Deferred warmup is consumed only once");
    expect<Session::WarmUp>(session.reduce(Session::WarmUpRequested{}), "A verified idle model can be prewarmed");
    expect<Session::CancelEngine>(session.reduce(Session::Cancel{}), "Idle cancellation also stops engine warmup");
    (void)session.reduce(Session::ModelPreparing{});
    (void)session.reduce(manual("Queued"));
    (void)session.reduce(Session::WarmUpRequested{});
    const auto cancelled = session.reduce(Session::Cancel{});
    expect<Session::Status>(cancelled, "Cancel queued work without creating an engine");
    require(std::get<Session::Status>(cancelled.front()) == Session::Status::Cancelled,
        "Queued cancellation reports a cancellation outcome");
    expect<>(session.reduce(Session::ModelReady{}), "Cancel drops both queued work and deferred warmup");
    require(!session.busy(), "Cancel leaves no active request");
}

void replacementAndStaleCallbacks() {
    Session session;
    (void)session.reduce(Session::ModelReady{});
    expect<Session::ClearOutput, Session::Status, Session::SubmitRequest>(
        session.reduce(manual("Old")), "A fresh submission resets output");
    requestStarted(session, 13);
    expect<Session::CancelEngine, Session::ClearOutput, Session::Status, Session::SubmitRequest>(
        session.reduce(selection("New")), "Cancel the old engine work before submitting the replacement");
    expect<>(session.reduce(Finished{13, Complete{"Premature completion", false, ToJapanese}}),
        "Completion before the engine acknowledges the new request is stale");
    requestStarted(session, 27);
    expect<>(session.reduce(Progress{13, "Late partial", ToJapanese}), "Stale progress cannot update the translator");
    expect<>(session.reduce(Finished{13, Complete{"Late result", false, ToJapanese}}), "Stale completion cannot finish the replacement");
    expect<>(session.reduce(Finished{13, Error{"Late failure"}}), "Stale errors cannot reach the translator");
    expect<>(session.reduce(EngineEvent{Lifecycle{Failed{"Lifecycle failure"}}}), "Lifecycle reports are not request errors");
    auto effects = session.reduce(Progress{27, u8"新しい", ToJapanese});
    expect<Session::Output>(effects, "Matching progress updates the translator");
    const auto & partial = std::get<Session::Output>(effects.front());
    require(partial.text == u8"新しい" && partial.direction == ToJapanese && session.busy(),
        "Progress preserves text and direction and is not terminal");
    effects = session.reduce(Finished{27, Complete{u8"新しい文", true, ToJapanese}});
    expect<Session::Output, Session::Status>(effects, "Completion publishes final output before its status");
    require(std::get<Session::Output>(effects.front()).text == u8"新しい文" &&
        std::get<Session::Status>(effects.back()) == Session::Status::Truncated && !session.busy(),
        "A truncated result still displays its text with a warning");
    expect<>(session.reduce(Finished{27, Cancelled{}}), "Duplicate terminal events are stale");
}

void rejectedEngineStartIsTerminal() {
    Session session;
    (void)session.reduce(Session::ModelReady{});
    (void)session.reduce(manual("Rejected"));
    expect<Session::TranslationError>(session.reduce(Session::RequestStarted{0}), "A rejected dispatch is terminal");
    require(!session.busy(), "A rejected dispatch must not leave the controls busy");
    expect<>(session.reduce(Session::RequestStarted{0}), "A duplicate rejection is stale");

    Session onboarding{Session::TranslatorAccess::AwaitingOnboarding};
    (void)onboarding.reduce(selection("Held"));
    (void)onboarding.reduce(Session::ModelReady{});
    (void)onboarding.reduce(trial({17}));
    const auto rejected = onboarding.reduce(Session::RequestStarted{0});
    expect<Session::TrialFinished>(rejected, "A rejected trial reports failure only to onboarding");
    require(!std::get<Session::TrialFinished>(rejected.front()).output && !onboarding.trialAttempt(),
        "The user can retry practice or resume the held selection");
    expect<Session::Status, Session::SubmitRequest>(
        onboarding.reduce(Session::OpenTranslator{}), "A rejected trial does not discard the held selection");
}

void requestErrorsAndRevalidation() {
    Session session;
    (void)session.reduce(Session::ModelReady{});
    auto start = [&session](Session::RequestId id) {
        expect<Session::ClearOutput, Session::Status, Session::SubmitRequest>(
            session.reduce(manual("Some text")), "A ready session submits immediately");
        requestStarted(session, id);
    };
    start(10);
    auto effects = session.reduce(Finished{10, Error{"Inference failed"}});
    expect<Session::TranslationError>(effects, "A current engine error reports a translation error");
    require(std::get<Session::TranslationError>(effects.front()).message == "Inference failed" && !session.busy(),
        "An engine error preserves its message and ends the request");
    start(20);
    effects = session.reduce(Finished{20, Cancelled{}});
    expect<Session::Status>(effects, "A current engine cancellation emits only a status");
    require(std::get<Session::Status>(effects.front()) == Session::Status::Cancelled && !session.busy(),
        "Engine cancellation is terminal");
    start(30);
    expect<Session::CancelEngine, Session::Status>(session.reduce(Session::Cancel{}), "Explicit cancellation stops inference");
    expect<>(session.reduce(Progress{30, "Late text", ToJapanese}), "Late progress cannot update cancelled output");
    start(40);
    expect<Session::CancelEngine>(session.reduce(Session::ModelPreparing{}), "Revalidation stops active inference");
    (void)session.reduce(manual("Fresh"));
    expect<Session::Status, Session::SubmitRequest>(session.reduce(Session::ModelReady{}), "New work waits through revalidation");
    requestStarted(session, 50);
    expect<>(session.reduce(Finished{40, Error{"Late failure"}}), "Old inference cannot affect the new request");
    expect<Session::Output, Session::Status>(
        session.reduce(Finished{50, Complete{"Fresh result", false, ToJapanese}}), "New inference can finish normally");
}

void modelFailureDropsQueuedWorkAndWarmup() {
    Session session{Session::TranslatorAccess::AwaitingOnboarding};
    (void)session.reduce(selection("Held"));
    (void)session.reduce(trial({28}));
    (void)session.reduce(Session::WarmUpRequested{});
    const auto failure = session.reduce(Session::ModelFailed{"Verification failed"});
    expect<Session::TrialDiscarded, Session::ModelError>(failure, "Verification failure discards the trial");
    require(std::get<Session::ModelError>(failure.back()).message == "Verification failed" && !session.busy(),
        "Verification failure reports an error and drops all queued work");
    const auto rejected = session.reduce(trial({29}));
    expect<Session::TrialFinished>(rejected, "A trial cannot start while model preparation has failed");
    require(!std::get<Session::TrialFinished>(rejected.front()).output, "A rejected trial has no output");
    expect<>(session.reduce(Session::OpenTranslator{}), "Opening does not revive discarded selections");
    (void)session.reduce(Session::ModelPreparing{});
    expect<>(session.reduce(Session::ModelReady{}), "Retry cannot resurrect dropped requests or warmup");
}

void trialInvalidationPreservesAQueuedSelection() {
    for (bool running : {false, true}) {
        Session session{Session::TranslatorAccess::AwaitingOnboarding};
        constexpr Session::TrialAttempt attempt{7};
        (void)session.reduce(selection("External selection"));
        expect<>(session.reduce(trial(attempt)), "Queuing a trial does not update translator output");
        expect<>(session.reduce(trial(attempt)), "Duplicate trial submission is a no-op");
        expect<>(session.reduce(Session::TrialInvalidated{{6}}), "Old invalidation cannot affect the current trial");
        if (running) {
            const auto ready = session.reduce(Session::ModelReady{});
            expect<Session::SubmitRequest>(ready, "Verification starts the trial before the held selection");
            require(std::get<Session::SubmitRequest>(ready.front()).source.text == "Practice", "Start the trial text");
            requestStarted(session, 23);
            expect<>(session.reduce(Progress{23, "Partial", ToJapanese}), "Trial progress is isolated from the translator");
            expect<Session::CancelEngine, Session::TrialDiscarded>(
                session.reduce(Session::TrialInvalidated{attempt}), "Invalidating running practice stops inference");
            expect<>(session.reduce(Finished{23, Complete{"Late practice", false, ToJapanese}}), "Late completion cannot revive a trial");
        } else {
            expect<Session::TrialDiscarded>(
                session.reduce(Session::TrialInvalidated{attempt}), "Invalidating queued practice does not cancel the engine");
        }
        expect<>(session.reduce(Session::ModelReady{}), "The verified model cannot bypass onboarding");
        const auto opened = session.reduce(Session::OpenTranslator{});
        expect<Session::Status, Session::SubmitRequest>(opened, "Opening the translator resumes the held selection");
        require(std::get<Session::SubmitRequest>(opened.back()).source.text == "External selection",
            "Practice must not erase the held selection");
    }
}

void trialCompletionAndOnboardingHandoff() {
    const std::pair<EngineEvent, bool> cases[] = {
        {Finished{40, Complete{u8"練習", false, ToJapanese}}, true},
        {Finished{40, Complete{"Truncated", true, ToJapanese}}, false},
        {Finished{40, Complete{"", false, ToJapanese}}, false},
        {Finished{40, Cancelled{}}, false},
        {Finished{40, Error{"Failed"}}, false},
    };
    for (const auto & [event, succeeds] : cases) {
        Session session{Session::TranslatorAccess::AwaitingOnboarding};
        constexpr Session::TrialAttempt attempt{11};
        (void)session.reduce(selection("Prior selection"));
        (void)session.reduce(Session::ModelReady{});
        expect<Session::SubmitRequest>(session.reduce(trial(attempt)), "A trial starts without resetting output");
        requestStarted(session, 40);
        const auto finished = session.reduce(event);
        expect<Session::TrialFinished>(finished, "Trial completion emits only a trial result");
        const auto & result = std::get<Session::TrialFinished>(finished.front());
        require(result.attempt == attempt && result.output.has_value() == succeeds && !session.trialAttempt(),
            "Only a complete nonempty trial produces usable output");
        expect<>(session.reduce(event), "Repeating completion cannot finish twice");
        if (succeeds) {
            require(result.output->text == u8"練習" && result.output->direction == ToJapanese,
                "A successful trial preserves the result and direction");
            expect<>(session.reduce(Session::OpenTranslator{Session::PendingSelection::Discard}),
                "Accepting the trial discards the held selection without starting inference");
            require(!session.busy(), "Accepting the trial leaves no pending work");
        } else {
            expect<Session::Status, Session::SubmitRequest>(
                session.reduce(Session::OpenTranslator{}), "Skipping practice resumes the held selection");
        }
    }
}

}

int main() {
    latestQueuedRequestWins();
    warmupAndCancellation();
    replacementAndStaleCallbacks();
    rejectedEngineStartIsTerminal();
    requestErrorsAndRevalidation();
    modelFailureDropsQueuedWorkAndWarmup();
    trialInvalidationPreservesAQueuedSelection();
    trialCompletionAndOnboardingHandoff();
}
