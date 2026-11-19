#include "TranslationEngine.h"
#include "TranslationPrompt.h"
#include "Utf8.h"

#include "llama.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <climits>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

namespace bawan {
namespace {

constexpr std::size_t kMaximumPrompt = 4096;
constexpr std::size_t kMaximumOutput = 4096;
constexpr std::size_t kBatchSize = 128;
constexpr std::size_t kContextGranularity = 256;
constexpr const char * kUnsupportedModel = "This PLaMo model is not supported.";
constexpr const char * kUnexpectedError = "An unexpected translation error occurred.";

const char * eventName(EngineEvent::Kind kind) noexcept {
    switch (kind) {
        case EngineEvent::Kind::Loading: return "Loading";
        case EngineEvent::Kind::Ready: return "Ready";
        case EngineEvent::Kind::Idle: return "Idle";
        case EngineEvent::Kind::Text: return "Text";
        case EngineEvent::Kind::Complete: return "Complete";
        case EngineEvent::Kind::Cancelled: return "Cancelled";
        case EngineEvent::Kind::Error: return "Error";
    }
    return "Unknown";
}

void logCallbackFailure(EngineEvent::Kind kind, std::uint64_t id, const char * message) noexcept {
    // Use a fixed buffer and C stdio so diagnostics cannot throw or reenter
    // the callback. Bound and escape details to prevent forged log entries.
    constexpr std::size_t limit = 256;
    constexpr char hex[] = "0123456789ABCDEF";
    char detail[limit * 4 + 1];
    std::size_t consumed = 0;
    std::size_t size = 0;
    for (; consumed < limit && message[consumed]; ++consumed) {
        const auto byte = static_cast<unsigned char>(message[consumed]);
        if (byte >= 0x20 && byte <= 0x7E && byte != '\\') {
            detail[size++] = static_cast<char>(byte);
        } else {
            detail[size++] = '\\';
            detail[size++] = 'x';
            detail[size++] = hex[byte >> 4];
            detail[size++] = hex[byte & 0x0F];
        }
    }
    detail[size] = '\0';
    std::fprintf(stderr, "[Bawan] TranslationEngine callback threw (event=%s, requestId=%llu): %s%s\n",
                 eventName(kind), static_cast<unsigned long long>(id), detail, message[consumed] ? "..." : "");
}

std::size_t contextSize(std::size_t promptTokens) {
    const auto output = std::min(kMaximumOutput, std::max<std::size_t>(512, promptTokens * 2 + 256));
    const auto total = promptTokens + output;
    return (total + kContextGranularity - 1) / kContextGranularity * kContextGranularity;
}

using Model = std::unique_ptr<llama_model, decltype(&llama_model_free)>;
using Context = std::unique_ptr<llama_context, decltype(&llama_free)>;
using Batch = std::unique_ptr<llama_batch_ext, decltype(&llama_batch_ext_free)>;
using Sampler = std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)>;

std::vector<llama_token> tokenize(const llama_vocab * vocab,
                                  const std::string & text, bool special,
                                  std::size_t tokenBudget = kMaximumPrompt) {
    if (text.size() > INT_MAX) {
        throw std::runtime_error("The text is too long. Select less text and try again.");
    }
    const auto length = static_cast<std::int32_t>(text.size());
    const auto required = llama_tokenize(vocab, text.data(), length, nullptr, 0, false, special);
    if (required == INT_MIN) { throw std::runtime_error("Unable to parse the text."); }
    if (required == 0) { return {}; }
    const auto count = required < 0 ? -required : required;
    if (static_cast<std::size_t>(count) > tokenBudget) {
        throw std::runtime_error("The text is too long. Select less text and try again (input limit: 4,096 tokens).");
    }
    std::vector<llama_token> tokens(static_cast<std::size_t>(count));
    const auto actual = llama_tokenize(vocab, text.data(), length, tokens.data(), count, false, special);
    if (actual < 0) { throw std::runtime_error("Unable to parse the text."); }
    tokens.resize(static_cast<std::size_t>(actual));
    return tokens;
}

std::string tokenPiece(const llama_vocab * vocab, llama_token token) {
    char local[256];
    const auto count = llama_token_to_piece(vocab, token, local, sizeof(local), 0, true);
    if (count >= 0) { return std::string(local, static_cast<std::size_t>(count)); }
    if (count == INT_MIN) { throw std::runtime_error("Unable to read the translation."); }
    std::string piece(static_cast<std::size_t>(-count), '\0');
    const auto actual = llama_token_to_piece(vocab, token, piece.data(), -count, 0, true);
    if (actual < 0) { throw std::runtime_error("Unable to read the translation."); }
    piece.resize(static_cast<std::size_t>(actual));
    return piece;
}

}

class TranslationEngine::Impl {
public:
    Impl(std::string modelPath, Callback callback, std::chrono::milliseconds idleTimeout)
        : modelPath_(std::move(modelPath)), callback_(std::move(callback)),
          idleTimeout_(std::max(idleTimeout, std::chrono::milliseconds::zero())),
          worker_([this] { run(); }) {}

    ~Impl() { shutdown(); }

    void warmUp() { submit(WorkerInstructions::WarmUp{}); }

    std::uint64_t translate(std::string text, Direction direction) {
        return submit(Request{0, std::move(text), direction});
    }

    void cancel() { submit(WorkerInstructions::Cancel{}); }

    void releaseMemory() { submit(WorkerInstructions::Release{}); }

    void shutdown() {
        submit(WorkerInstructions::Stop{});
        // Stop cancels model loading at its next progress callback, prompt
        // decoding between 128-token batches, and generation between tokens.
        // Backend init, model I/O/mapping, tokenization, context allocation,
        // each inference call, cleanup and an executing callback must return
        // before join can finish; there is no fixed wall-clock bound. Joining
        // keeps this Impl and worker-owned resources alive until cleanup ends.
        if (worker_.joinable()) { worker_.join(); }
    }

private:
    struct Request {
        std::uint64_t id;
        std::string text;
        Direction direction;
    };

    enum class FailureStage { Load, Request };

    class WorkerInstructions {
    public:
        struct Wait {};
        struct WarmUp {};
        struct Release {};
        struct Cancel {};
        struct Stop {};
        struct Translation {
            enum class Afterwards { Wait, Release };
            Request request;
            Afterwards afterwards;
        };
        using Command = std::variant<Request, WarmUp, Release, Cancel, Stop>;
        using Next = std::variant<Wait, WarmUp, Translation, Release, Stop>;
        struct Work {
            Next next;
            std::vector<std::uint64_t> dropped;
            std::uint64_t cancellation = 0;
        };

        // Called with mutex_ held. Priority and combination rules live here:
        // Stop is final and suppresses callbacks. Cancel drops queued work and
        // aborts the active load/translation, preserving any release obligation.
        // Translation is latest-wins; it preserves a release, then unloads.
        // Release replaces warm-up, never translation. Warm-up only fills Wait.
        // Replacing a queued translation owes exactly one Cancelled callback.
        std::uint64_t update(Command command) {
            auto * request = std::get_if<Request>(&command);
            const auto id = request ? ++revision_ : 0;
            if (std::holds_alternative<Stop>(command)) {
                if (stopped()) { return 0; }
                // The worker checks these atomics without mutex_. Publish Stop
                // before invalidating work so cancellation cannot emit callbacks.
                stopped_ = true;
                ++revision_;
                ++cancellation_;
                next_ = Stop{};
                dropped_.clear();
                return 0;
            }
            const bool cancel = std::holds_alternative<Cancel>(command);
            if (cancel) {
                ++revision_;
                ++cancellation_;
            }
            if (stopped()) { return id; }
            auto * translation = std::get_if<Translation>(&next_);
            const bool release = std::holds_alternative<Release>(next_) ||
                (translation && translation->afterwards == Translation::Afterwards::Release);
            if (request || cancel) {
                if (translation) { dropped_.push_back(translation->request.id); }
                if (request) {
                    request->id = id;
                    next_ = Translation{std::move(*request), release ?
                        Translation::Afterwards::Release : Translation::Afterwards::Wait};
                } else if (release) {
                    next_ = Release{};
                } else {
                    next_ = Wait{};
                }
            } else if (std::holds_alternative<Release>(command)) {
                if (translation) { translation->afterwards = Translation::Afterwards::Release; }
                else { next_ = Release{}; }
            } else if (std::holds_alternative<Wait>(next_)) {
                next_ = WarmUp{};
            }
            return id;
        }

        bool hasWork() const {
            return !std::holds_alternative<Wait>(next_) || !dropped_.empty();
        }

        Work take() {
            Work work{std::move(next_), {}, cancellation_.load()};
            work.dropped.swap(dropped_);
            next_ = Wait{};
            return work;
        }

        bool stopped() const { return stopped_.load(); }
        bool cancelled(std::uint64_t id) const { return stopped() || revision_.load() != id; }
        bool loadCancelled(std::uint64_t epoch) const {
            return stopped() || cancellation_.load() != epoch;
        }

    private:
        Next next_{Wait{}};
        std::vector<std::uint64_t> dropped_;
        // A replacement translation can reuse an in-flight load; only Cancel
        // and Stop advance its cancellation epoch.
        std::atomic<bool> stopped_{false};
        std::atomic<std::uint64_t> revision_{0};
        std::atomic<std::uint64_t> cancellation_{0};
    };

    struct LoadProgress {
        Impl * owner;
        std::uint64_t cancellation;
    };

    std::uint64_t submit(WorkerInstructions::Command command) {
        std::uint64_t id;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            id = instructions_.update(std::move(command));
        }
        changed_.notify_one();
        return id;
    }

    void emit(EngineEvent::Kind kind, std::uint64_t id = 0,
              std::string text = {}, bool truncated = false,
              Direction direction = Direction::Automatic) noexcept {
        if (instructions_.stopped()) { return; }
        try { callback_(EngineEvent{kind, id, std::move(text), truncated, direction}); }
        catch (const std::exception & error) { logCallbackFailure(kind, id, error.what()); }
        catch (...) { logCallbackFailure(kind, id, "non-standard exception"); }
    }

    void unload() {
        model_.reset();
        if (backendInitialized_) {
            llama_backend_free();
            backendInitialized_ = false;
            emit(EngineEvent::Kind::Idle);
        }
    }

    bool load(std::uint64_t cancellation) {
        if (model_) { return true; }
        if (instructions_.loadCancelled(cancellation)) { return false; }
        emit(EngineEvent::Kind::Loading, 0, "Loading the model…");
        if (instructions_.loadCancelled(cancellation)) {
            emit(EngineEvent::Kind::Cancelled);
            return false;
        }
        llama_backend_init();
        backendInitialized_ = true;
        if (instructions_.loadCancelled(cancellation)) {
            unload();
            emit(EngineEvent::Kind::Cancelled);
            return false;
        }
        auto modelParameters = llama_model_default_params();
        modelParameters.n_gpu_layers = -1;
        modelParameters.load_mode = LLAMA_LOAD_MODE_MMAP;
        LoadProgress progress{this, cancellation};
        modelParameters.progress_callback = [](float, void * opaque) {
            const auto * state = static_cast<LoadProgress *>(opaque);
            return !state->owner->instructions_.loadCancelled(state->cancellation);
        };
        modelParameters.progress_callback_user_data = &progress;
        model_.reset(llama_model_load_from_file(modelPath_.c_str(), modelParameters));
        if (instructions_.loadCancelled(cancellation)) {
            unload();
            emit(EngineEvent::Kind::Cancelled);
            return false;
        }
        if (!model_) { throw std::runtime_error("Unable to load the model. Please check the model file."); }
        const auto * vocab = llama_model_get_vocab(model_.get());
        bos_ = llama_vocab_bos(vocab);
        const auto stopTags = tokenize(vocab, "<|plamo:tag|>", true);
        if (bos_ == LLAMA_TOKEN_NULL || stopTags.size() != 1) {
            throw std::runtime_error(kUnsupportedModel);
        }
        stopTag_ = stopTags.front();
        emit(EngineEvent::Kind::Ready, 0, "Ready to translate");
        return true;
    }

    std::vector<llama_token> prompt(Request & request) {
        bool japanese = false;
        if (detail::utf8Prefix(request.text, &japanese) != request.text.size()) {
            throw std::runtime_error("The text is not valid UTF-8.");
        }
        if (request.text.find_first_not_of(" \t\r\n") == std::string::npos) {
            throw std::runtime_error("Enter text to translate.");
        }
        const bool toEnglish = request.direction == Direction::JapaneseToEnglish ||
            (request.direction == Direction::Automatic && japanese);
        request.direction = toEnglish ? Direction::JapaneseToEnglish : Direction::EnglishToJapanese;
        const auto * vocab = llama_model_get_vocab(model_.get());
        std::vector<llama_token> result{bos_};
        const auto prefix = tokenize(vocab, detail::translationPromptPrefix(request.text, toEnglish), true);
        const auto suffix = tokenize(vocab, std::string("<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>") +
            (toEnglish ? "en" : "ja") + "<|plamo:msg|>", true);
        const auto overhead = result.size() + prefix.size() + suffix.size();
        if (overhead > kMaximumPrompt) { throw std::runtime_error(kUnsupportedModel); }
        if (instructions_.cancelled(request.id)) return {};
        // Parse only the application's PFML3 delimiters as special tokens.
        // Keep the existing token limit, not a byte heuristic that could reject
        // valid input. llama_tokenize's sizing pass itself is not interruptible.
        const auto source = tokenize(vocab, request.text, false, kMaximumPrompt - overhead);
        if (instructions_.cancelled(request.id)) return {};
        result.reserve(overhead + source.size());
        result.insert(result.end(), prefix.begin(), prefix.end());
        result.insert(result.end(), source.begin(), source.end());
        result.insert(result.end(), suffix.begin(), suffix.end());
        return result;
    }

    void decode(llama_context * context, llama_batch_ext * batch,
                const llama_token * tokens, std::size_t count,
                std::size_t position, bool output) {
        llama_batch_ext_clear(batch);
        for (std::size_t token = 0; token < count; ++token) {
            const auto index = llama_batch_ext_add_token(batch, 0, tokens[token]);
            const auto pos = static_cast<llama_pos>(position + token);
            if (index < 0 || !llama_batch_ext_set_pos(batch, index, &pos) ||
                (output && token + 1 == count &&
                 !llama_batch_ext_set_output_logits(batch, index, true))) {
                throw std::runtime_error("Unable to prepare a translation batch.");
            }
        }
        if (llama_process(context, LLAMA_PROCESS_TYPE_DECODE, batch) != 0) {
            throw std::runtime_error("An inference error occurred during translation.");
        }
    }

    EngineEvent translate(Request & request) {
        if (!model_) { throw std::runtime_error("The model is not ready."); }
        const auto tokens = prompt(request);
        if (instructions_.cancelled(request.id)) { return {EngineEvent::Kind::Cancelled, request.id, {}}; }

        auto parameters = llama_context_default_params();
        const auto contextTokens = contextSize(tokens.size());
        const auto outputLimit = std::min(kMaximumOutput, contextTokens - tokens.size());
        parameters.n_ctx = static_cast<std::uint32_t>(contextTokens);
        parameters.n_batch = kBatchSize;
        parameters.n_ubatch = kBatchSize;
        parameters.n_seq_max = 1;
        parameters.n_outputs_max = 1;
        parameters.n_outputs_max_per_seq = 1;
        parameters.n_threads = static_cast<std::int32_t>(std::min(4u, std::max(1u, std::thread::hardware_concurrency())));
        parameters.n_threads_batch = parameters.n_threads;
        parameters.type_k = GGML_TYPE_F16;
        parameters.type_v = GGML_TYPE_F16;
        parameters.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
        parameters.swa_full = false;
        Context context(llama_init_from_model(model_.get(), parameters), llama_free);
        if (!context) { throw std::runtime_error("Unable to allocate memory for translation."); }
        Batch batch(llama_batch_ext_init(context.get()), llama_batch_ext_free);
        Sampler sampler(llama_sampler_chain_init(llama_sampler_chain_default_params()), llama_sampler_free);
        if (!batch || !sampler) { throw std::runtime_error("Unable to prepare the translation engine."); }
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_greedy());
        const auto * vocab = llama_model_get_vocab(model_.get());
        for (std::size_t position = 0; position < tokens.size(); position += kBatchSize) {
            if (instructions_.cancelled(request.id)) { return {EngineEvent::Kind::Cancelled, request.id, {}}; }
            const auto count = std::min(kBatchSize, tokens.size() - position);
            decode(context.get(), batch.get(), tokens.data() + position, count, position, position + count == tokens.size());
        }

        std::string output;
        std::size_t emittedBytes = 0;
        std::size_t validBytes = 0;
        auto lastEmission = std::chrono::steady_clock::time_point{};
        for (std::size_t generated = 0; generated < outputLimit; ++generated) {
            if (instructions_.cancelled(request.id)) { return {EngineEvent::Kind::Cancelled, request.id, {}}; }
            const auto token = llama_sampler_sample(sampler.get(), context.get(), -1);
            if (llama_vocab_is_eog(vocab, token) || token == stopTag_ || token == bos_) {
                if (validBytes != output.size()) { throw std::runtime_error("Unable to read the end of the translation."); }
                return {EngineEvent::Kind::Complete, request.id, std::move(output), false, request.direction};
            }
            output += tokenPiece(vocab, token);
            validBytes = detail::utf8Prefix(output, nullptr, validBytes);
            const auto now = std::chrono::steady_clock::now();
            if (validBytes != emittedBytes && (emittedBytes == 0 ||
                now - lastEmission >= std::chrono::milliseconds(33))) {
                emit(EngineEvent::Kind::Text, request.id, output.substr(0, validBytes), false, request.direction);
                emittedBytes = validBytes;
                lastEmission = now;
            }
            if (generated + 1 < outputLimit) {
                decode(context.get(), batch.get(), &token, 1, tokens.size() + generated, true);
            }
        }
        return {EngineEvent::Kind::Complete, request.id, output.substr(0, validBytes), true, request.direction};
    }

    void fail(FailureStage stage, const std::optional<Request> & request,
              std::uint64_t cancellation, const char * message) {
        if (stage == FailureStage::Load) {
            unload();
            emit(instructions_.loadCancelled(cancellation) ? EngineEvent::Kind::Cancelled : EngineEvent::Kind::Error,
                 0, message);
        }
        if (request) {
            if (instructions_.cancelled(request->id)) { emit(EngineEvent::Kind::Cancelled, request->id); }
            else { emit(EngineEvent::Kind::Error, request->id, message); }
        }
    }

    void run() {
        using Clock = std::chrono::steady_clock;
        auto idleDeadline = Clock::time_point::max();
        for (;;) {
            WorkerInstructions::Work work;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                const auto hasWork = [this] { return instructions_.hasWork(); };
                if (model_) {
                    if (!changed_.wait_until(lock, idleDeadline, hasWork)) {
                        lock.unlock();
                        unload();
                        continue;
                    }
                } else {
                    changed_.wait(lock, hasWork);
                }
                if (instructions_.stopped()) { break; }
                work = instructions_.take();
            }
            for (const auto id : work.dropped) { emit(EngineEvent::Kind::Cancelled, id); }
            if (std::holds_alternative<WorkerInstructions::Release>(work.next)) {
                unload();
                continue;
            }
            auto * translation = std::get_if<WorkerInstructions::Translation>(&work.next);
            if (!translation && (model_ ||
                !std::holds_alternative<WorkerInstructions::WarmUp>(work.next))) { continue; }
            std::optional<Request> request;
            if (translation) { request = std::move(translation->request); }
            const bool release = translation && translation->afterwards ==
                WorkerInstructions::Translation::Afterwards::Release;
            const auto cancellation = work.cancellation;
            auto failureStage = FailureStage::Load;
            try {
                if (request && instructions_.cancelled(request->id)) {
                    emit(EngineEvent::Kind::Cancelled, request->id);
                } else if (load(cancellation)) {
                    if (request) {
                        failureStage = FailureStage::Request;
                        auto result = translate(*request);
                        emit(result.kind, result.requestId, std::move(result.text), result.truncated, result.direction);
                    }
                } else if (request) {
                    emit(EngineEvent::Kind::Cancelled, request->id);
                }
            } catch (const std::exception & error) {
                fail(failureStage, request, cancellation, error.what());
            } catch (...) {
                fail(failureStage, request, cancellation, kUnexpectedError);
            }
            if (release) { unload(); }
            else if (model_) { idleDeadline = Clock::now() + idleTimeout_; }
        }
        unload();
    }

    const std::string modelPath_;
    Callback callback_;
    const std::chrono::milliseconds idleTimeout_;
    std::mutex mutex_;
    std::condition_variable changed_;
    WorkerInstructions instructions_;
    Model model_{nullptr, llama_model_free};
    llama_token bos_ = LLAMA_TOKEN_NULL;
    llama_token stopTag_ = LLAMA_TOKEN_NULL;
    bool backendInitialized_ = false;
    std::thread worker_;
};

TranslationEngine::TranslationEngine(std::string modelPath, Callback callback,
                                     std::chrono::milliseconds idleTimeout)
    : impl_(std::make_unique<Impl>(std::move(modelPath), std::move(callback), idleTimeout)) {}
TranslationEngine::~TranslationEngine() = default;
void TranslationEngine::warmUp() { impl_->warmUp(); }
std::uint64_t TranslationEngine::translate(std::string text, Direction direction) { return impl_->translate(std::move(text), direction); }
void TranslationEngine::cancel() { impl_->cancel(); }
void TranslationEngine::releaseMemory() { impl_->releaseMemory(); }
void TranslationEngine::shutdown() { impl_->shutdown(); }

}
