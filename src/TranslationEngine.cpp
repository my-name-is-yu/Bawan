#include "TranslationEngine.h"

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

namespace lore {
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
                                  const std::string & text, bool special) {
    if (text.size() > INT_MAX) {
        throw std::runtime_error("The text is too long. Select less text and try again.");
    }
    const auto length = static_cast<std::int32_t>(text.size());
    const auto required = llama_tokenize(vocab, text.data(), length, nullptr, 0, false, special);
    if (required == INT_MIN) { throw std::runtime_error("Unable to parse the text."); }
    if (required == 0) { return {}; }
    const auto count = required < 0 ? -required : required;
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
    explicit Impl(Callback callback)
        : callback_(std::move(callback)), worker_([this] { run(); }) {}

    ~Impl() { shutdown(); }

    void loadModel(std::string path) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (stopping_) { return; }
            ++revision_;
            ++loadRevision_;
            pendingRequest_.reset();
            pendingModel_ = std::move(path);
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
        std::lock_guard<std::mutex> lock(mutex_);
        ++revision_;
        pendingRequest_.reset();
    }

    void shutdown() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopping_ = true;
            ++revision_;
            pendingRequest_.reset();
            pendingModel_.reset();
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
        std::uint64_t revision;
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

    void resetResources() {
        batch_.reset();
        sampler_.reset();
        context_.reset();
        model_.reset();
    }

    void load(const std::string & path, std::uint64_t loadRevision) {
        resetResources();
        emit(EngineEvent::Kind::Loading, 0, "Loading the model…");
        auto modelParameters = llama_model_default_params();
        modelParameters.n_gpu_layers = -1;
        modelParameters.load_mode = LLAMA_LOAD_MODE_MMAP;
        LoadProgress progress{this, loadRevision};
        modelParameters.progress_callback = [](float, void * opaque) {
            const auto * state = static_cast<LoadProgress *>(opaque);
            return !state->owner->stopping_ && state->owner->loadRevision_.load() == state->revision;
        };
        modelParameters.progress_callback_user_data = &progress;
        model_.reset(llama_model_load_from_file(path.c_str(), modelParameters));
        if (stopping_ || loadRevision_.load() != loadRevision) { resetResources(); return; }
        if (!model_) { throw std::runtime_error("Unable to load the model. Please check the model file."); }

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
        context_.reset(llama_init_from_model(model_.get(), parameters));
        if (!context_) { throw std::runtime_error("Unable to allocate memory for translation."); }
        batch_.reset(llama_batch_ext_init(context_.get()));
        sampler_.reset(llama_sampler_chain_init(llama_sampler_chain_default_params()));
        if (!batch_ || !sampler_) { throw std::runtime_error("Unable to prepare the translation engine."); }
        // A chain retains llama.cpp's vocabulary-sized sampling scratch buffer;
        // passing the bare greedy sampler would allocate it for every token.
        llama_sampler_chain_add(sampler_.get(), llama_sampler_init_greedy());
        if (stopping_ || loadRevision_.load() != loadRevision) { resetResources(); return; }
        emit(EngineEvent::Kind::Ready, 0, "Ready to translate");
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
        const auto prefix = tokenize(vocab,
            "<|plamo:tag|>dataset<|plamo:msg|>translation"
            "<|plamo:tag|>input<|plamo:msg|>", true);
        // Parse only the application's PFML3 delimiters as special tokens.
        const auto source = tokenize(vocab, request.text, false);
        const auto suffix = tokenize(vocab, std::string("<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>") +
            (toEnglish ? "en" : "ja") + "<|plamo:msg|>", true);
        result.insert(result.end(), prefix.begin(), prefix.end());
        result.insert(result.end(), source.begin(), source.end());
        result.insert(result.end(), suffix.begin(), suffix.end());
        if (result.size() > kMaximumPrompt) {
            throw std::runtime_error("The text is too long. Select less text and try again (input limit: 4,096 tokens).");
        }
        return result;
    }

    void decode(const llama_token * tokens, std::size_t count,
                std::size_t position, bool output) {
        llama_batch_ext_clear(batch_.get());
        for (std::size_t token = 0; token < count; ++token) {
            const auto index = llama_batch_ext_add_token(batch_.get(), 0, tokens[token]);
            const auto pos = static_cast<llama_pos>(position + token);
            if (index < 0 || !llama_batch_ext_set_pos(batch_.get(), index, &pos) ||
                (output && token + 1 == count &&
                 !llama_batch_ext_set_output_logits(batch_.get(), index, true))) {
                throw std::runtime_error("Unable to prepare a translation batch.");
            }
        }
        if (llama_process(context_.get(), LLAMA_PROCESS_TYPE_DECODE, batch_.get()) != 0) {
            throw std::runtime_error("An inference error occurred during translation.");
        }
    }

    void translate(Request & request) {
        if (!context_) { throw std::runtime_error("The model is not ready."); }
        const auto tokens = prompt(request);
        llama_memory_clear(llama_get_memory(context_.get()), false);
        llama_sampler_reset(sampler_.get());
        const auto * vocab = llama_model_get_vocab(model_.get());
        for (std::size_t position = 0; position < tokens.size(); position += kBatchSize) {
            if (cancelled(request.id)) { emit(EngineEvent::Kind::Cancelled, request.id); return; }
            const auto count = std::min(kBatchSize, tokens.size() - position);
            decode(tokens.data() + position, count, position, position + count == tokens.size());
        }
        const auto stopTags = tokenize(vocab, "<|plamo:tag|>", true);
        const auto stopBos = llama_vocab_bos(vocab);
        if (stopTags.size() != 1) { throw std::runtime_error("This PLaMo model is not supported."); }

        std::string output;
        std::size_t emittedBytes = 0;
        std::size_t validBytes = 0;
        auto lastEmission = std::chrono::steady_clock::time_point{};
        for (std::size_t generated = 0; generated < kMaximumOutput; ++generated) {
            if (cancelled(request.id)) { emit(EngineEvent::Kind::Cancelled, request.id); return; }
            const auto token = llama_sampler_sample(sampler_.get(), context_.get(), -1);
            if (llama_vocab_is_eog(vocab, token) || token == stopTags.front() || token == stopBos) {
                if (validBytes != output.size()) { throw std::runtime_error("Unable to read the end of the translation."); }
                emit(EngineEvent::Kind::Complete, request.id, output, false, request.direction);
                return;
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
                decode(&token, 1, tokens.size() + generated, true);
            }
        }
        emit(EngineEvent::Kind::Complete, request.id, output.substr(0, validBytes), true, request.direction);
    }

    void run() {
        llama_backend_init();
        for (;;) {
            std::optional<std::string> modelPath;
            std::optional<Request> request;
            std::uint64_t modelRevision = 0;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                changed_.wait(lock, [this] { return stopping_ || pendingModel_ || pendingRequest_; });
                if (stopping_) { break; }
                if (pendingModel_) {
                    modelPath = std::move(pendingModel_);
                    pendingModel_.reset();
                    modelRevision = loadRevision_.load();
                } else {
                    request = std::move(pendingRequest_);
                    pendingRequest_.reset();
                }
            }
            try {
                if (modelPath) { load(*modelPath, modelRevision); }
                else if (request && !cancelled(request->id)) { translate(*request); }
            } catch (const std::exception & error) {
                if (modelPath) { resetResources(); }
                if (!request || !cancelled(request->id)) {
                    emit(EngineEvent::Kind::Error, request ? request->id : 0, error.what());
                } else { emit(EngineEvent::Kind::Cancelled, request->id); }
            } catch (...) {
                if (modelPath) { resetResources(); }
                emit(EngineEvent::Kind::Error, request ? request->id : 0, "An unexpected translation error occurred.");
            }
        }
        resetResources();
        llama_backend_free();
    }

    Callback callback_;
    std::mutex mutex_;
    std::condition_variable changed_;
    std::atomic<bool> stopping_{false};
    std::atomic<std::uint64_t> revision_{0};
    std::atomic<std::uint64_t> loadRevision_{0};
    std::optional<std::string> pendingModel_;
    std::optional<Request> pendingRequest_;
    Model model_{nullptr, llama_model_free};
    Context context_{nullptr, llama_free};
    Batch batch_{nullptr, llama_batch_ext_free};
    Sampler sampler_{nullptr, llama_sampler_free};
    std::thread worker_;
};

TranslationEngine::TranslationEngine(Callback callback) : impl_(std::make_unique<Impl>(std::move(callback))) {}
TranslationEngine::~TranslationEngine() = default;
void TranslationEngine::loadModel(std::string path) { impl_->loadModel(std::move(path)); }
std::uint64_t TranslationEngine::translate(std::string text, Direction direction) { return impl_->translate(std::move(text), direction); }
void TranslationEngine::cancel() { impl_->cancel(); }
void TranslationEngine::shutdown() { impl_->shutdown(); }

} // namespace lore
