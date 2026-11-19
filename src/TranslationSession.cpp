#include "TranslationSession.h"

#include <type_traits>
#include <utility>

namespace bawan {
namespace {

template <class... Handlers>
struct Overload : Handlers... { using Handlers::operator()...; };

template <class... Handlers>
Overload(Handlers...) -> Overload<Handlers...>;

}

TranslationSession::TranslationSession(TranslatorAccess access) {
    if (access == TranslatorAccess::AwaitingOnboarding) state_.surface = Onboarding{};
}

template <class Self, class F>
decltype(auto) TranslationSession::withWork(Self & self, F f) {
    return std::visit([&](auto & surface) { return f(surface.work); }, self.state_.surface);
}

template <class O>
TranslationSession::Phase TranslationSession::phaseOf(const Work<O> & work) {
    return std::visit(Overload{
        [](Idle) { return Phase::Idle; },
        [](const Queued<O> &) { return Phase::Queued; },
        [](const Starting<O> &) { return Phase::Starting; },
        [](const Running<O> &) { return Phase::Running; },
    }, work);
}

TranslationSession::Phase TranslationSession::phase() const {
    const auto workPhase = withWork(*this, [](const auto & work) { return phaseOf(work); });
    const auto * onboarding = std::get_if<Onboarding>(&state_.surface);
    return workPhase == Phase::Idle && onboarding && onboarding->selection ? Phase::Queued : workPhase;
}

template <class O>
std::optional<TranslationSession::RequestId> TranslationSession::requestIdOf(const Work<O> & work) {
    if (const auto * running = std::get_if<Running<O>>(&work)) return running->requestId;
    return std::nullopt;
}

std::optional<TranslationSession::RequestId> TranslationSession::activeRequestId() const {
    return withWork(*this, [](const auto & work) { return requestIdOf(work); });
}

std::optional<TranslationSession::TrialAttempt> TranslationSession::trialAttempt() const {
    const auto * onboarding = std::get_if<Onboarding>(&state_.surface);
    if (!onboarding) return std::nullopt;
    return std::visit(Overload{
        [](Idle) -> std::optional<TrialAttempt> { return std::nullopt; },
        [](const auto & trial) -> std::optional<TrialAttempt> { return trial.origin.attempt; },
    }, onboarding->work);
}

template <class O>
void TranslationSession::startRequest(Work<O> & work, Effects & effects) {
    if (auto * queued = std::get_if<Queued<O>>(&work)) {
        if constexpr (std::is_same_v<O, TranslatorOrigin>) effects.emplace_back(Status::Clear);
        effects.emplace_back(SubmitRequest{std::move(queued->source)});
        work = Starting<O>{queued->origin};
    }
}

template <class O>
void TranslationSession::acceptRequestId(Work<O> & work, RequestId id) {
    if (const auto * starting = std::get_if<Starting<O>>(&work)) work = Running<O>{id, starting->origin};
}

template <class O>
bool TranslationSession::interrupt(Work<O> & work, Effects & effects) {
    const bool running = std::holds_alternative<Running<O>>(work);
    if (running) effects.emplace_back(CancelEngine{});
    if constexpr (std::is_same_v<O, Trial>) {
        std::visit(Overload{
            [](Idle) {},
            [&](const auto & trial) { effects.emplace_back(TrialDiscarded{trial.origin.attempt}); },
        }, work);
    }
    work = Idle{};
    return running;
}

TranslationSession::Effects TranslationSession::reduce(Event event) {
    Effects effects;
    std::visit(Overload{
        [&](OpenTranslator opened) { openTranslator(opened, effects); },
        [&](ModelPreparing) {
            if (!std::holds_alternative<Preparing>(state_.model)) {
                resetWork(effects);
                state_.model = Preparing{};
            }
        },
        [&](ModelReady) { modelReady(effects); },
        [&](ModelFailed failed) {
            resetWork(effects);
            state_.model = Failed{};
            effects.emplace_back(ModelError{std::move(failed.message)});
        },
        [&](Submit submitted) { submit(std::move(submitted), effects); },
        [&](RequestStarted started) {
            withWork(*this, [&](auto & work) { acceptRequestId(work, started.requestId); });
        },
        [&](RequestRejected) {
            if (phase() != Phase::Starting) return;
            if (const auto attempt = trialAttempt()) effects.emplace_back(TrialFinished{*attempt, std::nullopt});
            else effects.emplace_back(TranslationError{"Unable to start translation."});
            withWork(*this, [](auto & work) { work = Idle{}; });
        },
        [&](Cancel) {
            const bool reportCancellation = busy() && !trialAttempt();
            resetWork(effects);
            if (reportCancellation) effects.emplace_back(Status::Cancelled);
        },
        [&](WarmUpRequested) {
            if (auto * preparing = std::get_if<Preparing>(&state_.model)) {
                preparing->warmUp = WarmUpPlan::Pending;
            } else if (std::holds_alternative<Ready>(state_.model) && !busy()) {
                effects.emplace_back(WarmUp{});
            }
        },
        [&](TrialInvalidated invalidated) {
            if (trialAttempt() == invalidated.attempt) {
                interrupt(std::get<Onboarding>(state_.surface).work, effects);
            }
        },
        [&](EngineEvent update) { receiveEngineEvent(std::move(update), effects); },
    }, std::move(event));
    return effects;
}

void TranslationSession::openTranslator(OpenTranslator event, Effects & effects) {
    auto * onboarding = std::get_if<Onboarding>(&state_.surface);
    if (!onboarding) return;
    interrupt(onboarding->work, effects);
    Translator translator;
    if (event.pending == PendingSelection::Resume && onboarding->selection) {
        translator.work = Queued<TranslatorOrigin>{std::move(*onboarding->selection), Selection{}};
    }
    state_.surface = std::move(translator);
    if (std::holds_alternative<Ready>(state_.model)) {
        startRequest(std::get<Translator>(state_.surface).work, effects);
    }
}

void TranslationSession::modelReady(Effects & effects) {
    const auto * preparing = std::get_if<Preparing>(&state_.model);
    const bool warmUp = preparing && preparing->warmUp == WarmUpPlan::Pending;
    state_.model = Ready{};
    withWork(*this, [&](auto & work) { startRequest(work, effects); });
    if (warmUp && !busy()) effects.emplace_back(WarmUp{});
}

void TranslationSession::resetWork(Effects & effects) {
    const bool running = phase() == Phase::Running;
    if (!running && std::holds_alternative<Ready>(state_.model)) effects.emplace_back(CancelEngine{});
    withWork(*this, [&](auto & work) { interrupt(work, effects); });
    if (auto * onboarding = std::get_if<Onboarding>(&state_.surface)) onboarding->selection.reset();
    if (auto * preparing = std::get_if<Preparing>(&state_.model)) preparing->warmUp = WarmUpPlan::None;
}

void TranslationSession::submit(Submit event, Effects & effects) {
    const auto * trial = std::get_if<Trial>(&event.origin);
    if (trial && (std::holds_alternative<Failed>(state_.model) ||
                   std::holds_alternative<Translator>(state_.surface))) {
        effects.emplace_back(TrialFinished{trial->attempt, std::nullopt});
        return;
    }
    if (std::holds_alternative<Failed>(state_.model)) return;
    const bool ready = std::holds_alternative<Ready>(state_.model);
    if (auto * onboarding = std::get_if<Onboarding>(&state_.surface)) {
        if (trial) {
            if (trialAttempt() == trial->attempt) return;
            interrupt(onboarding->work, effects);
            onboarding->work = Queued<Trial>{std::move(event.source), *trial};
            if (ready) startRequest(onboarding->work, effects);
            return;
        }
        if (!std::holds_alternative<Selection>(event.origin)) return;
        interrupt(onboarding->work, effects);
        onboarding->selection = std::move(event.source);
        effects.emplace_back(ClearOutput{});
        return;
    }
    const TranslatorOrigin origin = std::holds_alternative<Manual>(event.origin)
        ? TranslatorOrigin{Manual{}} : TranslatorOrigin{Selection{}};
    auto & work = std::get<Translator>(state_.surface).work;
    interrupt(work, effects);
    effects.emplace_back(ClearOutput{});
    work = Queued<TranslatorOrigin>{std::move(event.source), origin};
    if (ready) startRequest(work, effects);
}

void TranslationSession::receiveEngineEvent(EngineEvent event, Effects & effects) {
    using namespace engine;
    std::visit(Visitor{
        [](Lifecycle &) {},
        [&](Progress & progress) {
            if (activeRequestId() == progress.requestId && !trialAttempt()) {
                effects.emplace_back(Output{std::move(progress.textSoFar), progress.direction});
            }
        },
        [&](Finished & finished) {
            if (activeRequestId() != finished.requestId) return;
            if (const auto attempt = trialAttempt()) {
                auto * complete = std::get_if<Complete>(&finished.outcome);
                std::optional<Output> output;
                if (complete && !complete->truncated && !complete->text.empty()) {
                    output = Output{std::move(complete->text), complete->direction};
                }
                effects.emplace_back(TrialFinished{*attempt, std::move(output)});
            } else {
                std::visit(Visitor{
                    [&](Complete & complete) {
                        effects.emplace_back(Output{std::move(complete.text), complete.direction});
                        effects.emplace_back(complete.truncated ? Status::Truncated : Status::Clear);
                    },
                    [&](Cancelled) { effects.emplace_back(Status::Cancelled); },
                    [&](Error & error) { effects.emplace_back(TranslationError{std::move(error.message)}); },
                }, finished.outcome);
            }
            withWork(*this, [](auto & work) { work = Idle{}; });
        },
    }, event);
}

}
