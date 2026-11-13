#pragma once

#include "ShortInput.h"

#include <string>
#include <string_view>

namespace lore::detail {

struct PromptOptions {
    bool sourceEnglish = false;
    std::string_view context;
    std::string_view examples;
};

inline std::string promptPrefix(PromptOptions options) {
    std::string prefix = "<|plamo:tag|>dataset<|plamo:msg|>translation";
    if (!options.context.empty()) {
        prefix += "<|plamo:tag|>context<|plamo:msg|>";
        prefix += options.context;
    }
    prefix += options.examples;
    prefix += "<|plamo:tag|>input";
    if (options.sourceEnglish) prefix += "<|plamo:key|>lang<|plamo:val|>en";
    prefix += "<|plamo:msg|>";
    return prefix;
}

inline PromptOptions productionPrompt(std::string_view text, bool toEnglish) {
    const auto words = toEnglish ? 0 : shortEnglishWordCount(text);
    if (words == 1) return {true, {}, {}};
    if (words > 1) return {false, "英語から日本語への翻訳です。", {}};
    return {};
}

} // namespace lore::detail
