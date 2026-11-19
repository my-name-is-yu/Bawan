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
    if (access == TranslatorAccess::AwaitingOnboarding) surface_ = Onboarding{};
}

template <class Self, class F>
decltype(auto) TranslationSession::withWork(Self & self, F f) {
    return std::visit([&](auto & surface) { return f(surface.work); }, self.surface_);
}

template <class O>
TranslationSession::Phase TranslationSession::phaseOf(const Work<O> & work) {
    return std::visit(Overload{
        [](Idle) { return Phase::Idle; },
        [](DeferredWarmUp) { return Phase::Idle; },
        [](const Queued<O> &) { return Phase::Queued; },
        [](const Starting<O> &) { return Phase::Starting; },
        [](const Running<O> &) { return Phase::Running; },
    }, work);
}

TranslationSession::Phase TranslationSession::phase() const {
    const auto workPhase = withWork(*this, [](const auto & work) { return phaseOf(work); });
    const auto * onboarding = std::get_if<Onboarding>(&surface_);
    return workPhase == Phase::Idle && onboarding && onboarding->selection ? Phase::Queued : workPhase;
}

TranslationSession::TranslatorAccess TranslationSession::access() const {
    return std::holds_alternative<Onboarding>(surface_) ? TranslatorAccess::AwaitingOnboarding : TranslatorAccess::Open;
}

template <class O>
std::optional<TranslationSession::RequestId> TranslationSession::requestIdOf(const Work<O> & work) {
    if (const auto * running = std::get_if<Running<O>>(&work)) return running->requestId;
    return std::nullopt;
}

std::optional<TranslationSession::RequestId> TranslationSession::activeRequestId() const {
    return withWork(*this, [](const auto & work) { return requestIdOf(work); });
}

bool TranslationSession::practicing() const {
    return withWork(*this, [](const auto & work) { return isTrial(work); });
}

template <class O>
bool TranslationSession::isTrial(const Work<O> & work) {
    if constexpr (std::is_same_v<O, Trial>) {
        return phaseOf(work) != Phase::Idle;
    } else {
        const auto hasTrialOrigin = [](const auto & active) { return std::holds_alternative<Trial>(active.origin); };
        return std::visit(Overload{
            [](Idle) { return false; },
            [](DeferredWarmUp) { return false; },
            hasTrialOrigin,
        }, work);
    }
}

template <class O>
void TranslationSession::startRequest(Work<O> & work, Effects & effects) {
    if (auto * queued = std::get_if<Queued<O>>(&work)) {
        if (!isTrial(work)) effects.emplace_back(Status::Clear);
        effects.emplace_back(SubmitRequest{std::move(queued->source)});
        work = Starting<O>{queued->origin};
    }
}

template <class O>
void TranslationSession::acceptRequestId(Work<O> & work, RequestId id) {
    if (const auto * starting = std::get_if<Starting<O>>(&work)) work = Running<O>{id, starting->origin};
}

template <class O>
void TranslationSession::interrupt(Work<O> & work, Effects & effects) {
    if (std::holds_alternative<Running<O>>(work)) effects.emplace_back(CancelEngine{});
    if (isTrial(work)) effects.emplace_back(TrialDiscarded{});
    work = Idle{};
}

TranslationSession::Effects TranslationSession::reduce(Event event, ModelAvailability model) {
    Effects effects;
    std::visit(Overload{
        [&](OpenTranslator opened) { openTranslator(opened, model, effects); },
        [&](Submit submitted) { submit(std::move(submitted), model, effects); },
        [&](Cancel) {
            const bool reportCancellation = busy() && !practicing();
            resetWork(model, effects);
            if (reportCancellation) effects.emplace_back(Status::Cancelled);
        },
        [&](WarmUpRequested) {
            if (model == ModelAvailability::Available && !busy()) effects.emplace_back(WarmUp{});
            if (model == ModelAvailability::Pending) withWork(*this, [](auto & work) {
                if (std::holds_alternative<Idle>(work)) work = DeferredWarmUp{};
            });
        },
        [&](TrialInvalidated) {
            if (practicing()) withWork(*this, [&](auto & work) { interrupt(work, effects); });
        },
        [&](EngineEvent update) { receiveEngineEvent(std::move(update), effects); },
    }, std::move(event));
    return effects;
}

TranslationSession::Effects TranslationSession::synchronizeModel(ModelAvailability model) {
    Effects effects;
    switch (model) {
        case ModelAvailability::Pending: break;
        case ModelAvailability::Available: drainPendingWork(effects); break;
        case ModelAvailability::Failed: resetWork(model, effects); break;
    }
    return effects;
}

TranslationSession::Effects TranslationSession::resolveSubmission(std::optional<RequestId> id) {
    if (phase() != Phase::Starting) return {};
    if (id) {
        withWork(*this, [&](auto & work) { acceptRequestId(work, *id); });
        return {};
    }
    Effects effects;
    if (practicing()) effects.emplace_back(TrialFinished{std::nullopt});
    else effects.emplace_back(TranslationError{"Unable to start translation."});
    withWork(*this, [](auto & work) { work = Idle{}; });
    return effects;
}

void TranslationSession::openTranslator(OpenTranslator event, ModelAvailability model, Effects & effects) {
    auto * onboarding = std::get_if<Onboarding>(&surface_);
    if (!onboarding) {
        auto & work = std::get<Translator>(surface_).work;
        if (isTrial(work)) interrupt(work, effects);
        return;
    }
    const bool warmUp = std::holds_alternative<DeferredWarmUp>(onboarding->work);
    interrupt(onboarding->work, effects);
    Translator translator;
    if (event.pending == PendingSelection::Resume && onboarding->selection) {
        translator.work = Queued<Origin>{std::move(*onboarding->selection), Selection{}};
    } else if (warmUp) {
        translator.work = DeferredWarmUp{};
    }
    surface_ = std::move(translator);
    if (model == ModelAvailability::Available) drainPendingWork(effects);
}

void TranslationSession::drainPendingWork(Effects & effects) {
    withWork(*this, [&](auto & work) {
        if (std::holds_alternative<DeferredWarmUp>(work)) {
            work = Idle{};
            if (!busy()) effects.emplace_back(WarmUp{});
        } else {
            startRequest(work, effects);
        }
    });
}

void TranslationSession::resetWork(ModelAvailability model, Effects & effects) {
    const bool running = phase() == Phase::Running;
    if (!running && model == ModelAvailability::Available) effects.emplace_back(CancelEngine{});
    withWork(*this, [&](auto & work) { interrupt(work, effects); });
    if (auto * onboarding = std::get_if<Onboarding>(&surface_)) onboarding->selection.reset();
}

void TranslationSession::submit(Submit event, ModelAvailability model, Effects & effects) {
    const bool trial = std::holds_alternative<Trial>(event.origin);
    if (trial && model == ModelAvailability::Failed) {
        effects.emplace_back(TrialFinished{std::nullopt});
        return;
    }
    if (model == ModelAvailability::Failed) return;
    const bool ready = model == ModelAvailability::Available;
    if (auto * onboarding = std::get_if<Onboarding>(&surface_)) {
        if (trial) {
            if (practicing()) return;
            onboarding->work = Queued<Trial>{std::move(event.source), Trial{}};
            if (ready) startRequest(onboarding->work, effects);
            return;
        }
        if (!std::holds_alternative<Selection>(event.origin)) return;
        interrupt(onboarding->work, effects);
        onboarding->selection = std::move(event.source);
        effects.emplace_back(ClearOutput{});
        return;
    }
    auto & work = std::get<Translator>(surface_).work;
    if (trial && practicing()) return;
    interrupt(work, effects);
    if (!trial) effects.emplace_back(ClearOutput{});
    work = Queued<Origin>{std::move(event.source), std::move(event.origin)};
    if (ready) startRequest(work, effects);
}

void TranslationSession::receiveEngineEvent(EngineEvent event, Effects & effects) {
    using namespace engine;
    std::visit(Visitor{
        [](Lifecycle &) {},
        [&](Progress & progress) {
            if (activeRequestId() == progress.requestId && !practicing()) {
                effects.emplace_back(Output{std::move(progress.textSoFar), progress.direction});
            }
        },
        [&](Finished & finished) {
            if (activeRequestId() != finished.requestId) return;
            if (practicing()) {
                auto * complete = std::get_if<Complete>(&finished.outcome);
                std::optional<Output> output;
                if (complete && !complete->truncated && !complete->text.empty()) {
                    output = Output{std::move(complete->text), complete->direction};
                }
                effects.emplace_back(TrialFinished{std::move(output)});
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
