#include "TranslationSession.h"

#include <utility>

namespace bawan {
namespace {

template <class... Handlers>
struct Overload : Handlers... { using Handlers::operator()...; };

template <class... Handlers>
Overload(Handlers...) -> Overload<Handlers...>;

}

TranslationSession::Effects TranslationSession::reduce(Event event) {
    Effects effects;
    std::visit(Overload{
        [&](OpenTranslator opened) {
            if (access_ == TranslatorAccess::Open) return;
            access_ = TranslatorAccess::Open;
            if (activeTrial()) {
                interrupt(effects);
                restoreSelection();
            }
            if (const auto * queued = std::get_if<Queued>(&state_);
                opened.pending == PendingSelection::Discard &&
                queued && std::holds_alternative<Selection>(queued->origin)) {
                state_ = Idle{};
            }
            advance(effects);
        },
        [&](ModelPreparing) {
            if (model_ != ModelAvailability::Preparing) resetWork(effects);
            model_ = ModelAvailability::Preparing;
        },
        [&](ModelReady) {
            model_ = ModelAvailability::Ready;
            advance(effects);
        },
        [&](ModelFailed failed) {
            resetWork(effects);
            model_ = ModelAvailability::Failed;
            effects.emplace_back(ModelError{std::move(failed.message)});
        },
        [&](Submit submitted) { submit(std::move(submitted), effects); },
        [&](Cancel) {
            const bool reportCancellation = !std::holds_alternative<Idle>(state_) && !activeTrial();
            resetWork(effects);
            if (reportCancellation) effects.emplace_back(Status::Cancelled);
        },
        [&](WarmUpRequested) {
            if (model_ == ModelAvailability::Failed || std::holds_alternative<Running>(state_)) return;
            if (model_ == ModelAvailability::Preparing || std::holds_alternative<Idle>(state_)) {
                warmUpPending_ = true;
                advance(effects);
            }
        },
        [&](TrialInvalidated invalidated) {
            const auto * trial = activeTrial();
            if (!trial || !(trial->attempt == invalidated.attempt)) return;
            interrupt(effects);
            restoreSelection();
            advance(effects);
        },
        [&](EngineEvent update) { handleEngineEvent(std::move(update), effects); },
    }, std::move(event));
    return effects;
}

void TranslationSession::advance(Effects & effects) {
    if (model_ != ModelAvailability::Ready) return;
    if (auto * queued = std::get_if<Queued>(&state_)) {
        if (access_ != TranslatorAccess::Open && !std::holds_alternative<Trial>(queued->origin)) return;
        const RequestId id{++lastRequestId_};
        effects.emplace_back(SubmitRequest{id, std::move(queued->source)});
        state_ = Running{id, queued->origin};
        warmUpPending_ = false;
    } else if (std::holds_alternative<Idle>(state_) && std::exchange(warmUpPending_, false)) {
        effects.emplace_back(WarmUp{});
    }
}

const TranslationSession::Trial * TranslationSession::activeTrial() const {
    if (const auto * queued = std::get_if<Queued>(&state_)) return std::get_if<Trial>(&queued->origin);
    if (const auto * running = std::get_if<Running>(&state_)) return std::get_if<Trial>(&running->origin);
    return nullptr;
}

void TranslationSession::interrupt(Effects & effects) {
    if (std::holds_alternative<Running>(state_)) effects.emplace_back(CancelEngine{});
    if (const auto * trial = activeTrial()) effects.emplace_back(TrialDiscarded{trial->attempt});
    state_ = Idle{};
}

void TranslationSession::resetWork(Effects & effects) {
    if (model_ == ModelAvailability::Ready && !std::holds_alternative<Running>(state_)) {
        effects.emplace_back(CancelEngine{});
    }
    interrupt(effects);
    suspendedSelection_.reset();
    warmUpPending_ = false;
}

void TranslationSession::restoreSelection() {
    if (auto selection = std::exchange(suspendedSelection_, std::nullopt)) {
        state_ = Queued{std::move(*selection), Selection{}};
    }
}

void TranslationSession::submit(Submit event, Effects & effects) {
    const auto * trial = std::get_if<Trial>(&event.origin);
    if (model_ == ModelAvailability::Failed) {
        if (trial) effects.emplace_back(TrialFinished{trial->attempt, std::nullopt});
        return;
    }
    if (trial) {
        if (const auto * active = activeTrial(); active && active->attempt == trial->attempt) return;
        if (auto * queued = std::get_if<Queued>(&state_); queued && std::holds_alternative<Selection>(queued->origin)) {
            suspendedSelection_ = std::move(queued->source);
        }
    } else {
        suspendedSelection_.reset();
    }

    interrupt(effects);
    if (!trial) {
        effects.emplace_back(ClearOutput{});
        effects.emplace_back(Status::Clear);
    }
    state_ = Queued{std::move(event.source), event.origin};
    advance(effects);
}

void TranslationSession::handleEngineEvent(EngineEvent event, Effects & effects) {
    const auto * running = std::get_if<Running>(&state_);
    if (!running || !(running->requestId == event.requestId)) return;
    const auto * trial = std::get_if<Trial>(&running->origin);
    if (auto * progress = std::get_if<Progress>(&event.update)) {
        if (!trial) effects.emplace_back(std::move(progress->output));
        return;
    }

    if (trial) {
        std::optional<Output> output;
        if (auto * complete = std::get_if<Complete>(&event.update);
            complete && !complete->truncated && !complete->output.text.empty()) {
            output = std::move(complete->output);
        }
        effects.emplace_back(TrialFinished{trial->attempt, std::move(output)});
    } else {
        std::visit(Overload{
            [](Progress) {},
            [&](Complete complete) {
                effects.emplace_back(std::move(complete.output));
                effects.emplace_back(complete.truncated ? Status::Truncated : Status::Clear);
            },
            [&](Cancelled) { effects.emplace_back(Status::Cancelled); },
            [&](EngineError error) { effects.emplace_back(TranslationError{std::move(error.message)}); },
        }, std::move(event.update));
    }
    state_ = Idle{};
    restoreSelection();
    advance(effects);
}

}
