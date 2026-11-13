#pragma once

#include <cstddef>
#include <string_view>

namespace lore {

// Zero means this is outside the short-English policy. Count words, not model
// tokens; unsupported scripts must not accidentally count as ASCII fragments.
inline std::size_t shortEnglishWordCount(std::string_view text) {
    const auto letter = [](unsigned char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    };
    const auto alphanumeric = [&](unsigned char c) {
        return letter(c) || (c >= '0' && c <= '9');
    };
    std::size_t words = 0;
    bool inWord = false;
    bool hasLetter = false;
    for (std::size_t position = 0; position < text.size();) {
        const auto c = static_cast<unsigned char>(text[position]);
        if (alphanumeric(c)) {
            if (!inWord && ++words > 5) return 0;
            inWord = true;
            hasLetter = hasLetter || letter(c);
            ++position;
            continue;
        }
        std::size_t width = 1;
        bool connector = c == '\'' || c == '-';
        if (c >= 0x80) {
            const auto matches = [&](std::string_view character) {
                return text.compare(position, character.size(), character) == 0;
            };
            if (matches(u8"‘") || matches(u8"’") || matches(u8"‐") || matches(u8"‑")) {
                width = 3;
                connector = true;
            } else if (matches(u8"\u00a0")) {
                width = 2;
            } else if (matches(u8"“") || matches(u8"”") || matches(u8"–") ||
                       matches(u8"—") || matches(u8"…") || matches(u8"\u2028") ||
                       matches(u8"\u2029") || matches(u8"\u202f") ||
                       matches(u8"\u205f") || matches(u8"\u3000")) {
                width = 3;
            } else if (position + 2 < text.size() && c == 0xE2 &&
                       static_cast<unsigned char>(text[position + 1]) == 0x80 &&
                       static_cast<unsigned char>(text[position + 2]) >= 0x80 &&
                       static_cast<unsigned char>(text[position + 2]) <= 0x8A) {
                width = 3; // U+2000 through U+200A: typographic spaces.
            } else {
                return 0;
            }
        } else if ((c < 0x20 && (c < '\t' || c > '\r')) || c == 0x7F) {
            return 0;
        }
        // Apostrophes and hyphens join only inside a word. Quotes and doubled
        // hyphens remain separators, so punctuation cannot hide a sixth word.
        inWord = connector && inWord && position + width < text.size() &&
            alphanumeric(static_cast<unsigned char>(text[position + width]));
        position += width;
    }
    return hasLetter ? words : 0;
}

} // namespace lore
