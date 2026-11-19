#pragma once

#include "Utf8.h"

#include <cstddef>
#include <string_view>

namespace bawan {
namespace detail {

// Latin-1 letters (excluding multiplication/division), Extended-A/B and
// Extended Additional cover accents and ligatures used in Latin-script text.
inline bool shortInputLetter(char32_t c) {
    return (c >= U'a' && c <= U'z') || (c >= U'A' && c <= U'Z') ||
        (c >= 0x00C0 && c <= 0x00D6) || (c >= 0x00D8 && c <= 0x00F6) ||
        (c >= 0x00F8 && c <= 0x024F) || (c >= 0x1E00 && c <= 0x1EFF);
}

inline bool shortInputAlphanumeric(char32_t c) {
    return shortInputLetter(c) || (c >= U'0' && c <= U'9');
}

inline bool shortInputSeparator(char32_t c) {
    // Printable ASCII, Unicode spaces, typographic punctuation, and common
    // Latin-1/currency symbols separate words. Format controls are excluded.
    return (c >= 0x20 && c <= 0x7E) || (c >= U'\t' && c <= U'\r') ||
        c == 0x00A0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) ||
        c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000 ||
        (c >= 0x2010 && c <= 0x2027) || (c >= 0x2030 && c <= 0x205E) ||
        (c >= 0x00A1 && c <= 0x00A9) || (c >= 0x00AB && c <= 0x00AC) ||
        (c >= 0x00AE && c <= 0x00B1) || c == 0x00B4 ||
        (c >= 0x00B6 && c <= 0x00B8) || c == 0x00BB || c == 0x00BF ||
        c == 0x00D7 || c == 0x00F7 || c == 0x20AC || c == 0x2122;
}

}

// A 1–5 word Latin-script heuristic, not language identification. Japanese and
// other scripts, emoji, controls, malformed UTF-8 and numbers alone return zero.
// Apostrophes/hyphens join adjacent alphanumerics; every other separator breaks
// words. Combining accents U+0300–036F must follow a Latin letter or its accents.
inline std::size_t shortEnglishWordCount(std::string_view text) {
    std::size_t words = 0;
    bool inWord = false;
    bool hasLetter = false;
    bool afterLetter = false;
    try {
        for (std::size_t position = 0; position < text.size();) {
            const auto character = detail::decodeUtf8(text, position);
            if (!character) return 0;
            const auto c = *character;
            if (detail::shortInputAlphanumeric(c)) {
                if (!inWord && ++words > 5) return 0;
                inWord = true;
                afterLetter = detail::shortInputLetter(c);
                hasLetter = hasLetter || afterLetter;
                continue;
            }
            if (c >= 0x0300 && c <= 0x036F) {
                if (!afterLetter) return 0;
                continue;
            }
            if (!detail::shortInputSeparator(c)) return 0;
            const bool connector = c == U'\'' || c == U'-' ||
                c == 0x2018 || c == 0x2019 || c == 0x2010 || c == 0x2011;
            auto nextPosition = position;
            const auto next = connector && inWord ? detail::decodeUtf8(text, nextPosition) : std::nullopt;
            inWord = next && detail::shortInputAlphanumeric(*next);
            afterLetter = false;
        }
    } catch (const std::runtime_error &) {
        return 0;
    }
    return hasLetter ? words : 0;
}

}
