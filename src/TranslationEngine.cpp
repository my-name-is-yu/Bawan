#include "TranslationEngine.h"
#include "TranslationPrompt.h"

#include "llama.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <climits>
#include <condition_variable>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <thread>
#include <utility>
#include <vector>

namespace bawan {
namespace {

constexpr std::size_t kMaximumPrompt = 4096;
constexpr std::size_t kMaximumOutput = 4096;
constexpr std::size_t kBatchSize = 128;

using Model = std::unique_ptr<llama_model, decltype(&llama_model_free)>;
using Context = std::unique_ptr<llama_context, decltype(&llama_free)>;
using Batch = std::unique_ptr<llama_batch_ext, decltype(&llama_batch_ext_free)>;
using Sampler = std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)>;

// Return the end of the valid UTF-8 prefix. A token can end partway through a
// character, so incomplete trailing bytes wait for the next generated token.
std::size_t utf8Prefix(const std::string & text, bool * japanese = nullptr,
                       std::size_t offset = 0) {
    while (offset < text.size()) {
        const auto first = static_cast<unsigned char>(text[offset]);
        std::size_t width;
        std::uint32_t codepoint;
        if (first < 0x80) { width = 1; codepoint = first; }
        else if (first >= 0xC2 && first <= 0xDF) { width = 2; codepoint = first & 0x1F; }
        else if (first >= 0xE0 && first <= 0xEF) { width = 3; codepoint = first & 0x0F; }
        else if (first >= 0xF0 && first <= 0xF4) { width = 4; codepoint = first & 0x07; }
        else { throw std::runtime_error("The text is not valid UTF-8."); }
        if (offset + width > text.size()) { return offset; }
        for (std::size_t byte = 1; byte < width; ++byte) {
            const auto next = static_cast<unsigned char>(text[offset + byte]);
            if ((next & 0xC0) != 0x80) {
                throw std::runtime_error("The text is not valid UTF-8.");
            }
            codepoint = (codepoint << 6) | (next & 0x3F);
        }
        if ((width == 2 && codepoint < 0x80) ||
            (width == 3 && codepoint < 0x800) ||
            (width == 4 && codepoint < 0x10000) ||
            (codepoint >= 0xD800 && codepoint <= 0xDFFF) || codepoint > 0x10FFFF) {
            throw std::runtime_error("The text is not valid UTF-8.");
        }
        if (japanese && ((codepoint >= 0x3040 && codepoint <= 0x30FF) ||
                         (codepoint >= 0x31F0 && codepoint <= 0x31FF) ||
                         (codepoint >= 0xFF66 && codepoint <= 0xFF9F) ||
                         (codepoint >= 0x3400 && codepoint <= 0x4DBF) ||
                         (codepoint >= 0x4E00 && codepoint <= 0x9FFF) ||
                         (codepoint >= 0xF900 && codepoint <= 0xFAFF) ||
                         (codepoint >= 0x20000 && codepoint <= 0x323AF) ||
                         (codepoint >= 0x3005 && codepoint <= 0x3007))) {
            *japanese = true;
        }
        offset += width;
    }
    return offset;
}

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
    // Reject before allocating/filling a token vector for input we cannot use.
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

} // namespace

class TranslationEngine::Impl {
public:
    Impl(std::string modelPath, Callback callback, std::chrono::milliseconds idleTimeout)
        : modelPath_(std::move(modelPath)), callback_(std::move(callback)),
          idleTimeout_(std::max(idleTimeout, std::chrono::milliseconds::zero())),
          worker_([this] { run(); }) {}

    ~Impl() { shutdown(); }

    void warmUp() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (stopping_) { return; }
            pendingWarmUp_ = true;
        }
        changed_.notify_one();
    }

    std::uint64_t translate(std::string text, Direction direction) {
        std::uint64_t id;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            id = ++revision_;
            if (stopping_) { return id; }
            pendingRequest_ = Request{id, std::move(text), direction};
        }
        changed_.notify_one();
        return id;
    }

    void cancel() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            ++revision_;
            ++cancellation_;
            pendingRequest_.reset();
            pendingWarmUp_ = false;
        }
        changed_.notify_one();
    }

    void shutdown() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopping_ = true;
            ++revision_;
            ++cancellation_;
            pendingRequest_.reset();
            pendingWarmUp_ = false;
        }
        changed_.notify_one();
        if (worker_.joinable()) { worker_.join(); }
    }

private:
    struct Request {
        std::uint64_t id;
        std::string text;
        Direction direction;
    };

    struct LoadProgress {
        Impl * owner;
        std::uint64_t cancellation;
    };

    bool cancelled(std::uint64_t id) const {
        return stopping_ || revision_.load() != id;
    }

    void emit(EngineEvent::Kind kind, std::uint64_t id = 0,
              std::string text = {}, bool truncated = false,
              Direction direction = Direction::Automatic) noexcept {
        if (stopping_) { return; }
        try { callback_(EngineEvent{kind, id, std::move(text), truncated, direction}); }
        catch (...) { /* Never unwind across the inference thread boundary. */ }
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
        if (stopping_ || cancellation_.load() != cancellation) { return false; }
        emit(EngineEvent::Kind::Loading, 0, "Loading the model…");
        if (stopping_ || cancellation_.load() != cancellation) {
            emit(EngineEvent::Kind::Cancelled);
            return false;
        }
        llama_backend_init();
        backendInitialized_ = true;
        if (stopping_ || cancellation_.load() != cancellation) {
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
            return !state->owner->stopping_ &&
                state->owner->cancellation_.load() == state->cancellation;
        };
        modelParameters.progress_callback_user_data = &progress;
        model_.reset(llama_model_load_from_file(modelPath_.c_str(), modelParameters));
        if (stopping_ || cancellation_.load() != cancellation) {
            unload();
            emit(EngineEvent::Kind::Cancelled);
            return false;
        }
        if (!model_) { throw std::runtime_error("Unable to load the model. Please check the model file."); }
        emit(EngineEvent::Kind::Ready, 0, "Ready to translate");
        return true;
    }

    std::vector<llama_token> prompt(Request & request) {
        bool japanese = false;
        if (utf8Prefix(request.text, &japanese) != request.text.size()) {
            throw std::runtime_error("The text is not valid UTF-8.");
        }
        if (request.text.find_first_not_of(" \t\r\n") == std::string::npos) {
            throw std::runtime_error("Enter text to translate.");
        }
        const bool toEnglish = request.direction == Direction::JapaneseToEnglish ||
            (request.direction == Direction::Automatic && japanese);
        request.direction = toEnglish ? Direction::JapaneseToEnglish : Direction::EnglishToJapanese;
        const auto * vocab = llama_model_get_vocab(model_.get());
        const auto bos = llama_vocab_bos(vocab);
        if (bos == LLAMA_TOKEN_NULL) { throw std::runtime_error("This PLaMo model is not supported."); }
        std::vector<llama_token> result{bos};
        const auto prefix = tokenize(vocab, detail::translationPromptPrefix(request.text, toEnglish), true);
        const auto suffix = tokenize(vocab, std::string("<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>") +
            (toEnglish ? "en" : "ja") + "<|plamo:msg|>", true);
        const auto overhead = result.size() + prefix.size() + suffix.size();
        if (overhead > kMaximumPrompt) {
            throw std::runtime_error("This PLaMo model is not supported.");
        }
        if (cancelled(request.id)) return {};
        // Parse only the application's PFML3 delimiters as special tokens.
        // Keep the existing token limit, not a byte heuristic that could reject
        // valid input. llama_tokenize's sizing pass itself is not interruptible.
        const auto source = tokenize(vocab, request.text, false, kMaximumPrompt - overhead);
        if (cancelled(request.id)) return {};
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
        if (cancelled(request.id)) { return {EngineEvent::Kind::Cancelled, request.id, {}}; }

        // Keep only the model resident. Request-local resources are released on
        // success, cancellation and exceptions, before a terminal event is sent.
        auto parameters = llama_context_default_params();
        parameters.n_ctx = kMaximumPrompt + kMaximumOutput;
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
        // Reuse vocabulary-sized sampling scratch within this translation.
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_greedy());
        const auto * vocab = llama_model_get_vocab(model_.get());
        for (std::size_t position = 0; position < tokens.size(); position += kBatchSize) {
            if (cancelled(request.id)) { return {EngineEvent::Kind::Cancelled, request.id, {}}; }
            const auto count = std::min(kBatchSize, tokens.size() - position);
            decode(context.get(), batch.get(), tokens.data() + position, count, position, position + count == tokens.size());
        }
        const auto stopTags = tokenize(vocab, "<|plamo:tag|>", true);
        const auto stopBos = llama_vocab_bos(vocab);
        if (stopTags.size() != 1) { throw std::runtime_error("This PLaMo model is not supported."); }

        std::string output;
        std::size_t emittedBytes = 0;
        std::size_t validBytes = 0;
        auto lastEmission = std::chrono::steady_clock::time_point{};
        for (std::size_t generated = 0; generated < kMaximumOutput; ++generated) {
            if (cancelled(request.id)) { return {EngineEvent::Kind::Cancelled, request.id, {}}; }
            const auto token = llama_sampler_sample(sampler.get(), context.get(), -1);
            if (llama_vocab_is_eog(vocab, token) || token == stopTags.front() || token == stopBos) {
                if (validBytes != output.size()) { throw std::runtime_error("Unable to read the end of the translation."); }
                return {EngineEvent::Kind::Complete, request.id, std::move(output), false, request.direction};
            }
            output += tokenPiece(vocab, token);
            validBytes = utf8Prefix(output, nullptr, validBytes);
            const auto now = std::chrono::steady_clock::now();
            if (validBytes != emittedBytes && (emittedBytes == 0 ||
                now - lastEmission >= std::chrono::milliseconds(33))) {
                emit(EngineEvent::Kind::Text, request.id, output.substr(0, validBytes), false, request.direction);
                emittedBytes = validBytes;
                lastEmission = now;
            }
            if (generated + 1 < kMaximumOutput) {
                decode(context.get(), batch.get(), &token, 1, tokens.size() + generated, true);
            }
        }
        return {EngineEvent::Kind::Complete, request.id, output.substr(0, validBytes), true, request.direction};
    }

    void run() {
        using Clock = std::chrono::steady_clock;
        auto idleDeadline = Clock::time_point::max();
        for (;;) {
            std::optional<Request> request;
            std::uint64_t cancellation = 0;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                const auto hasWork = [this] { return stopping_ || pendingWarmUp_ || pendingRequest_; };
                if (model_) {
                    if (!changed_.wait_until(lock, idleDeadline, hasWork)) {
                        lock.unlock();
                        unload();
                        continue;
                    }
                } else {
                    changed_.wait(lock, hasWork);
                }
                if (stopping_) { break; }
                request = std::move(pendingRequest_);
                pendingRequest_.reset();
                pendingWarmUp_ = false;
                cancellation = cancellation_.load();
            }
            // Repeated warmUp calls neither reload a hot model nor extend its
            // idle lifetime. A request queued during prewarming reuses the load.
            if (!request && model_) { continue; }
            try {
                if (request && cancelled(request->id)) {
                    emit(EngineEvent::Kind::Cancelled, request->id);
                } else if (load(cancellation)) {
                    if (request) {
                        auto result = translate(*request);
                        emit(result.kind, result.requestId, std::move(result.text), result.truncated, result.direction);
                    }
                } else if (request) {
                    emit(EngineEvent::Kind::Cancelled, request->id);
                }
            } catch (const std::exception & error) {
                if (!model_) {
                    unload();
                    emit(cancellation_.load() != cancellation ? EngineEvent::Kind::Cancelled : EngineEvent::Kind::Error,
                         0, error.what());
                }
                if (request) {
                    if (cancelled(request->id)) { emit(EngineEvent::Kind::Cancelled, request->id); }
                    else { emit(EngineEvent::Kind::Error, request->id, error.what()); }
                }
            } catch (...) {
                if (!model_) {
                    unload();
                    emit(cancellation_.load() != cancellation ? EngineEvent::Kind::Cancelled : EngineEvent::Kind::Error,
                         0, "An unexpected translation error occurred.");
                }
                if (request) {
                    if (cancelled(request->id)) { emit(EngineEvent::Kind::Cancelled, request->id); }
                    else { emit(EngineEvent::Kind::Error, request->id, "An unexpected translation error occurred."); }
                }
            }
            if (model_) { idleDeadline = Clock::now() + idleTimeout_; }
        }
        unload();
    }

    const std::string modelPath_;
    Callback callback_;
    const std::chrono::milliseconds idleTimeout_;
    std::mutex mutex_;
    std::condition_variable changed_;
    std::atomic<bool> stopping_{false};
    std::atomic<std::uint64_t> revision_{0};
    std::atomic<std::uint64_t> cancellation_{0};
    bool pendingWarmUp_ = false;
    std::optional<Request> pendingRequest_;
    Model model_{nullptr, llama_model_free};
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
void TranslationEngine::shutdown() { impl_->shutdown(); }

} // namespace bawan
