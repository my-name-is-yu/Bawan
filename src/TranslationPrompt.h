#pragma once

#include "ShortInput.h"

#include <string>
#include <string_view>

namespace lore::detail {

inline std::string translationPromptPrefix(std::string_view text, bool toEnglish) {
    const auto words = toEnglish ? 0 : shortEnglishWordCount(text);
    std::string prefix = "<|plamo:tag|>dataset<|plamo:msg|>translation";
    if (words > 1) {
        prefix += "<|plamo:tag|>context<|plamo:msg|>英語から日本語への翻訳です。";
    }
    prefix += "<|plamo:tag|>input";
    if (words == 1) prefix += "<|plamo:key|>lang<|plamo:val|>en";
    prefix += "<|plamo:msg|>";
    return prefix;
}

} // namespace lore::detail
