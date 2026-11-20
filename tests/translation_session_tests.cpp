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
using Model = Session::ModelAvailability;
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

Session::Submit trial() {
    return {{"Practice", Direction::Automatic}, Session::Trial{}};
}

struct Fixture {
    Session session;
    Model availability = Model::Pending;

    explicit Fixture(Session::TranslatorAccess access = Session::TranslatorAccess::Open) : session(access) {}

    Session::Effects reduce(Session::Event event) {
        return session.reduce(std::move(event), availability);
    }

    Session::Effects synchronizeModel(Model model) {
        availability = model;
        return session.synchronizeModel(availability);
    }

    Session::Effects resolveSubmission(std::optional<Session::RequestId> id) { return session.resolveSubmission(id); }

    Phase phase() const { return session.phase(); }
    bool busy() const { return session.busy(); }
    std::optional<Session::RequestId> activeRequestId() const { return session.activeRequestId(); }
};

void requestStarted(Fixture & session, Session::RequestId id) {
    require(session.phase() == Phase::Starting && !session.activeRequestId(),
        "The reducer must wait for the engine-assigned ID after emitting a submit");
    expect<>(session.resolveSubmission(id), "Acknowledging an engine ID emits no further effects");
    require(session.phase() == Phase::Running && session.activeRequestId() == id, "Track the engine-assigned ID");
}

void anAlreadyVerifiedModelNeedsNoReadinessReplay() {
    Session session;
    expect<Session::ClearOutput, Session::Status, Session::SubmitRequest>(
        session.reduce(manual("Immediate"), Model::Available),
        "Submission consults current verified availability without replaying setup events");
}

void latestQueuedRequestWins() {
    Fixture session;
    expect<Session::ClearOutput>(session.reduce(manual("First")), "Queuing clears stale output");
    (void)session.reduce(manual(u8"次の文", ToEnglish));
    require(session.phase() == Phase::Queued, "Unverified work stays queued");
    expect<>(session.reduce(Session::WarmUpRequested{}), "Warmup waits for verification");
    expect<>(session.synchronizeModel(Model::Pending), "Preparation updates keep pending work queued");
    const auto effects = session.synchronizeModel(Model::Available);
    expect<Session::Status, Session::SubmitRequest>(effects, "The pending request takes priority over prewarming");
    const auto & source = std::get<Session::SubmitRequest>(effects.back()).source;
    require(source.text == u8"次の文" && source.direction == ToEnglish, "Readiness submits the latest text and direction");
    requestStarted(session, 61);
    expect<>(session.synchronizeModel(Model::Available), "Repeated readiness must not replay a request");
}

void warmupAndCancellation() {
    Fixture session;
    expect<>(session.reduce(Session::WarmUpRequested{}), "Prewarming waits for verification");
    expect<>(session.reduce(Session::WarmUpRequested{}), "Pending prewarm requests coalesce");
    expect<Session::WarmUp>(session.synchronizeModel(Model::Available), "Verification releases the deferred warmup");
    expect<>(session.synchronizeModel(Model::Available), "Deferred warmup is consumed only once");
    expect<Session::WarmUp>(session.reduce(Session::WarmUpRequested{}), "A verified idle model can be prewarmed");
    expect<Session::CancelEngine>(session.reduce(Session::Cancel{}), "Idle cancellation also stops engine warmup");
    (void)session.synchronizeModel(Model::Pending);
    (void)session.reduce(manual("Queued"));
    (void)session.reduce(Session::WarmUpRequested{});
    const auto cancelled = session.reduce(Session::Cancel{});
    expect<Session::Status>(cancelled, "Cancel queued work without creating an engine");
    require(std::get<Session::Status>(cancelled.front()) == Session::Status::Cancelled,
        "Queued cancellation reports a cancellation outcome");
    expect<>(session.synchronizeModel(Model::Available), "Cancel drops both queued work and deferred warmup");
    require(!session.busy(), "Cancel leaves no active request");
}

void replacementAndStaleCallbacks() {
    Fixture session;
    (void)session.synchronizeModel(Model::Available);
    expect<Session::ClearOutput, Session::Status, Session::SubmitRequest>(
        session.reduce(manual("Old")), "A fresh submission resets output");
    requestStarted(session, 13);
    expect<Session::ClearOutput, Session::Status, Session::SubmitRequest>(
        session.reduce(selection("New")), "Submit a replacement without cancelling the engine's reusable model load");
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
    Fixture session;
    (void)session.synchronizeModel(Model::Available);
    (void)session.reduce(manual("Rejected"));
    expect<Session::TranslationError>(session.resolveSubmission(std::nullopt), "A rejected dispatch is terminal");
    require(!session.busy(), "A rejected dispatch must not leave the controls busy");
    expect<>(session.resolveSubmission(std::nullopt), "A duplicate rejection is stale");

    Fixture onboarding{Session::TranslatorAccess::AwaitingOnboarding};
    (void)onboarding.reduce(selection("Held"));
    (void)onboarding.synchronizeModel(Model::Available);
    (void)onboarding.reduce(trial());
    const auto rejected = onboarding.resolveSubmission(std::nullopt);
    expect<Session::TrialFinished>(rejected, "A rejected trial reports failure only to onboarding");
    require(!std::get<Session::TrialFinished>(rejected.front()).output,
        "The user can retry practice or resume the held selection");
    expect<Session::Status, Session::SubmitRequest>(
        onboarding.reduce(Session::OpenTranslator{}), "A rejected trial does not discard the held selection");
}

void requestErrorsAndRevalidation() {
    Fixture session;
    (void)session.synchronizeModel(Model::Available);
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
    expect<Session::CancelEngine>(session.synchronizeModel(Model::Failed), "Model failure retires active inference");
    (void)session.synchronizeModel(Model::Pending);
    (void)session.reduce(manual("Fresh"));
    expect<Session::Status, Session::SubmitRequest>(session.synchronizeModel(Model::Available), "New work waits through revalidation");
    requestStarted(session, 50);
    expect<>(session.reduce(Finished{40, Error{"Late failure"}}), "Old inference cannot affect the new request");
    expect<Session::Output, Session::Status>(
        session.reduce(Finished{50, Complete{"Fresh result", false, ToJapanese}}), "New inference can finish normally");
}

void modelFailureDropsQueuedWorkAndWarmup() {
    Fixture session{Session::TranslatorAccess::AwaitingOnboarding};
    (void)session.reduce(selection("Held"));
    (void)session.reduce(trial());
    (void)session.reduce(Session::WarmUpRequested{});
    const auto failure = session.synchronizeModel(Model::Failed);
    expect<Session::TrialDiscarded>(failure, "Verification failure discards the trial");
    require(!session.busy(), "Verification failure drops all queued work");
    const auto rejected = session.reduce(trial());
    expect<Session::TrialFinished>(rejected, "A trial cannot start while model preparation has failed");
    require(!std::get<Session::TrialFinished>(rejected.front()).output, "A rejected trial has no output");
    expect<>(session.reduce(Session::OpenTranslator{}), "Opening does not revive discarded selections");
    (void)session.synchronizeModel(Model::Pending);
    expect<>(session.synchronizeModel(Model::Available), "Retry cannot resurrect dropped requests or warmup");
}

void trialInvalidationPreservesAQueuedSelection() {
    for (bool running : {false, true}) {
        Fixture session{Session::TranslatorAccess::AwaitingOnboarding};
        (void)session.reduce(selection("External selection"));
        expect<>(session.reduce(trial()), "Queuing a trial does not update translator output");
        expect<>(session.reduce(trial()), "Duplicate trial submission is a no-op");
        if (running) {
            const auto ready = session.synchronizeModel(Model::Available);
            expect<Session::SubmitRequest>(ready, "Verification starts the trial before the held selection");
            require(std::get<Session::SubmitRequest>(ready.front()).source.text == "Practice", "Start the trial text");
            requestStarted(session, 23);
            expect<>(session.reduce(Progress{23, "Partial", ToJapanese}), "Trial progress is isolated from the translator");
            expect<Session::CancelEngine, Session::TrialDiscarded>(
                session.reduce(Session::TrialInvalidated{}), "Invalidating running practice stops inference");
            expect<>(session.reduce(Finished{23, Complete{"Late practice", false, ToJapanese}}), "Late completion cannot revive a trial");
        } else {
            expect<Session::TrialDiscarded>(
                session.reduce(Session::TrialInvalidated{}), "Invalidating queued practice does not cancel the engine");
        }
        expect<>(session.reduce(Session::TrialInvalidated{}), "Repeating an interruption after practice ended is a no-op");
        expect<>(session.synchronizeModel(Model::Available), "The verified model cannot bypass onboarding");
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
        Fixture session{Session::TranslatorAccess::AwaitingOnboarding};
        (void)session.reduce(selection("Prior selection"));
        (void)session.synchronizeModel(Model::Available);
        expect<Session::SubmitRequest>(session.reduce(trial()), "A trial starts without resetting output");
        requestStarted(session, 40);
        const auto finished = session.reduce(event);
        expect<Session::TrialFinished>(finished, "Trial completion emits only a trial result");
        const auto & result = std::get<Session::TrialFinished>(finished.front());
        require(result.output.has_value() == succeeds,
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

void returningUserCanPracticeWithoutGatingTheTranslator() {
    Fixture session;
    expect<>(session.synchronizeModel(Model::Available), "Verification with no pending work is a no-op");
    expect<Session::SubmitRequest>(session.reduce(trial()), "Revisited setup can start a practice request");
    requestStarted(session, 16);
    expect<Session::CancelEngine, Session::TrialDiscarded>(session.reduce(Session::OpenTranslator{}),
        "Leaving revisited setup retires its practice without resetting translator access");
    expect<Session::ClearOutput, Session::Status, Session::SubmitRequest>(session.reduce(manual("Translate")),
        "Manual translation remains available after revisited setup");
}


}

int main() {
    anAlreadyVerifiedModelNeedsNoReadinessReplay();
    returningUserCanPracticeWithoutGatingTheTranslator();
    latestQueuedRequestWins();
    warmupAndCancellation();
    replacementAndStaleCallbacks();
    rejectedEngineStartIsTerminal();
    requestErrorsAndRevalidation();
    modelFailureDropsQueuedWorkAndWarmup();
    trialInvalidationPreservesAQueuedSelection();
    trialCompletionAndOnboardingHandoff();
}
