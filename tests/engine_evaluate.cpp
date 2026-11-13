#include "TranslationEngine.h"
#include "EvaluationPrompt.h"

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include <sys/resource.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#endif

namespace {
using Clock = std::chrono::steady_clock;

std::string context;
std::string examples;
std::string rule;
bool sourceEnglish = false;

struct Result {
    lore::EngineEvent event;
    std::optional<Clock::time_point> firstText;
    Clock::time_point completed;
};

class Events {
public:
    void push(lore::EngineEvent event) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!latest_ || latest_->requestId != event.requestId) firstText_.reset();
        if (event.kind == lore::EngineEvent::Kind::Text && !firstText_) firstText_ = Clock::now();
        latest_ = std::move(event);
        updated_ = Clock::now();
        changed_.notify_one();
    }
    Result wait(std::uint64_t id) {
        std::unique_lock<std::mutex> lock(mutex_);
        if (!changed_.wait_for(lock, std::chrono::seconds(120), [&] {
            if (!latest_ || latest_->requestId != id) return false;
            using Kind = lore::EngineEvent::Kind;
            return latest_->kind == Kind::Complete || latest_->kind == Kind::Cancelled ||
                latest_->kind == Kind::Error || (id == 0 && latest_->kind == Kind::Ready);
        })) throw std::runtime_error("Timed out waiting for the engine");
        return {*latest_, firstText_, updated_};
    }
private:
    std::mutex mutex_;
    std::condition_variable changed_;
    std::optional<lore::EngineEvent> latest_;
    std::optional<Clock::time_point> firstText_;
    Clock::time_point updated_;
};

std::string unhex(const std::string & text) {
    if (text.size() % 2) throw std::runtime_error("Invalid hex field");
    const auto digit = [](char c) -> unsigned {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        throw std::runtime_error("Invalid hex digit");
    };
    std::string result;
    result.reserve(text.size() / 2);
    for (std::size_t i = 0; i < text.size(); i += 2) result += static_cast<char>(digit(text[i]) * 16 + digit(text[i + 1]));
    return result;
}

std::string json(const std::string & text) {
    std::ostringstream out;
    out << '"';
    for (unsigned char c : text) {
        if (c == '"' || c == '\\') out << '\\' << c;
        else if (c < 0x20) out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c) << std::dec;
        else out << c;
    }
    out << '"';
    return out.str();
}

void memory() {
    rusage resource{};
    getrusage(RUSAGE_SELF, &resource);
#if defined(__APPLE__)
    mach_task_basic_info_data_t basic{};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    const auto rss = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, reinterpret_cast<task_info_t>(&basic), &count) == KERN_SUCCESS
        ? static_cast<std::int64_t>(basic.resident_size) : -1;
    task_vm_info_data_t vm{};
    count = TASK_VM_INFO_COUNT;
    const auto footprint = task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&vm), &count) == KERN_SUCCESS
        ? static_cast<std::int64_t>(vm.phys_footprint) : -1;
    std::cout << ",\"current_rss_bytes\":" << rss << ",\"physical_footprint_bytes\":" << footprint
              << ",\"max_rss_bytes\":" << resource.ru_maxrss;
#else
    std::cout << ",\"current_rss_bytes\":null,\"physical_footprint_bytes\":null,\"max_rss_bytes\":"
              << static_cast<std::int64_t>(resource.ru_maxrss) * 1024;
#endif
}
double milliseconds(Clock::time_point start, Clock::time_point end) {
    return std::chrono::duration<double, std::milli>(end - start).count();
}
} // namespace

namespace lore::detail {
PromptOptions evaluationPrompt(std::string_view text, bool toEnglish) {
    const auto words = toEnglish ? 0 : shortEnglishWordCount(text);
    if (words == 0) return {};
    if (rule == "single_en" && words == 1) return {true, {}, {}};
    return {sourceEnglish, context, examples};
}
} // namespace lore::detail

int main(int argc, char ** argv) {
    if (argc != 2) { std::cerr << "Usage: engine_evaluate MODEL_PATH < requests.tsv\n"; return EXIT_FAILURE; }
    try {
        Events events;
        lore::TranslationEngine engine([&](lore::EngineEvent event) { events.push(std::move(event)); });
        const auto loadStart = Clock::now();
        engine.loadModel(argv[1]);
        const auto loaded = events.wait(0);
        if (loaded.event.kind != lore::EngineEvent::Kind::Ready) throw std::runtime_error(loaded.event.text);
        std::cout << std::fixed << std::setprecision(3) << "{\"type\":\"ready\",\"model_load_ms\":" << milliseconds(loadStart, loaded.completed);
        memory();
        std::cout << "}" << std::endl;
        std::string line;
        while (std::getline(std::cin, line)) {
            std::vector<std::string> fields;
            std::size_t begin = 0;
            for (;;) {
                const auto end = line.find('\t', begin);
                fields.push_back(line.substr(begin, end == std::string::npos ? end : end - begin));
                if (end == std::string::npos) break;
                begin = end + 1;
            }
            // All arbitrary text fields are UTF-8 encoded as hex by the Python
            // runner; tabs, embedded NULs and newlines cannot alter framing.
            if (fields.size() != 8) throw std::runtime_error("Expected eight TSV fields");
            sourceEnglish = fields[2] == "1";
            rule = fields[3];
            context = unhex(fields[4]);
            examples = unhex(fields[5]);
            const auto direction = fields[6] == "en_to_ja" ? lore::Direction::EnglishToJapanese :
                fields[6] == "ja_to_en" ? lore::Direction::JapaneseToEnglish : lore::Direction::Automatic;
            const auto source = unhex(fields[7]);
            const auto start = Clock::now();
            const auto result = events.wait(engine.translate(source, direction));
            std::cout << "{\"type\":\"result\",\"id\":" << json(fields[0]) << ",\"variant\":" << json(fields[1])
                      << ",\"output\":" << json(result.event.text)
                      << ",\"complete\":" << (result.event.kind == lore::EngineEvent::Kind::Complete ? "true" : "false")
                      << ",\"truncated\":" << (result.event.truncated ? "true" : "false")
                      << ",\"direction\":" << json(result.event.direction == lore::Direction::JapaneseToEnglish ? "ja_to_en" : "en_to_ja")
                      << ",\"short_words\":" << lore::shortEnglishWordCount(source)
                      << ",\"first_text_ms\":";
            if (result.firstText) std::cout << milliseconds(start, *result.firstText); else std::cout << "null";
            std::cout << ",\"completion_ms\":" << milliseconds(start, result.completed);
            memory();
            std::cout << "}" << std::endl;
        }
        engine.shutdown();
    } catch (const std::exception & error) {
        std::cerr << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
