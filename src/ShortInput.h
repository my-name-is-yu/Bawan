#pragma once

#include <cstddef>
#include <string_view>

namespace lore {

// Count English words rather than model tokens. Unsupported Unicode text stays
// on the ordinary translation path instead of counting only its ASCII pieces.
// Zero means that the input is not eligible, including inputs over five words.
inline std::size_t shortEnglishWordCount(std::string_view text) {
    const auto isLetter = [](unsigned char byte) {
        return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
    };
    const auto isAlphanumeric = [&](unsigned char byte) {
        return isLetter(byte) || (byte >= '0' && byte <= '9');
    };

    std::size_t words = 0;
    bool inWord = false;
    bool hasLetter = false;
    for (std::size_t position = 0; position < text.size();) {
        const auto byte = static_cast<unsigned char>(text[position]);
        if (isAlphanumeric(byte)) {
            if (!inWord && ++words > 5) { return 0; }
            inWord = true;
            hasLetter = hasLetter || isLetter(byte);
            ++position;
            continue;
        }

        std::size_t width = 1;
        bool connector = byte == '\'' || byte == '-';
        if (byte >= 0x80) {
            const auto matches = [&](std::string_view character) {
                return text.compare(position, character.size(), character) == 0;
            };
            if (matches(u8"‘") || matches(u8"’") ||
                matches(u8"‐") || matches(u8"‑")) {
                width = 3;
                connector = true;
            } else if (matches(u8"\u00a0")) {
                width = 2;
            } else if (matches(u8"“") || matches(u8"”") ||
                       matches(u8"–") || matches(u8"—") || matches(u8"…") ||
                       matches(u8"\u2028") || matches(u8"\u2029") ||
                       matches(u8"\u202f") || matches(u8"\u205f") ||
                       matches(u8"\u3000")) {
                width = 3;
            } else if (position + 2 < text.size() && byte == 0xE2 &&
                       static_cast<unsigned char>(text[position + 1]) == 0x80 &&
                       static_cast<unsigned char>(text[position + 2]) >= 0x80 &&
                       static_cast<unsigned char>(text[position + 2]) <= 0x8A) {
                // U+2000 through U+200A are typographic spaces.
                width = 3;
            } else {
                return 0;
            }
        } else if ((byte < 0x20 && (byte < '\t' || byte > '\r')) || byte == 0x7F) {
            return 0;
        }

        // Apostrophes and hyphens join words only when surrounded by letters or
        // digits. Outer quotes, dashes and all other punctuation separate words.
        inWord = connector && inWord && position + width < text.size() &&
            isAlphanumeric(static_cast<unsigned char>(text[position + width]));
        position += width;
    }
    return hasLetter ? words : 0;
}

inline bool isShortEnglishInput(std::string_view text) {
    return shortEnglishWordCount(text) != 0;
}

} // namespace lore
