#pragma once

#include <cstddef>
#include <optional>
#include <stdexcept>
#include <string_view>

namespace bawan::detail {

// Consume one Unicode scalar. An incomplete tail leaves offset unchanged;
// bytes that cannot become valid UTF-8 throw, even in an incomplete tail.
inline std::optional<char32_t> decodeUtf8(std::string_view text, std::size_t &offset) {
    if (offset > text.size()) throw std::out_of_range("UTF-8 offset is beyond the text.");
    if (offset == text.size()) return std::nullopt;

    const auto first = static_cast<unsigned char>(text[offset]);
    std::size_t width;
    char32_t codepoint;
    if (first < 0x80) { width = 1; codepoint = first; }
    else if (first >= 0xC2 && first <= 0xDF) { width = 2; codepoint = first & 0x1F; }
    else if (first >= 0xE0 && first <= 0xEF) { width = 3; codepoint = first & 0x0F; }
    else if (first >= 0xF0 && first <= 0xF4) { width = 4; codepoint = first & 0x07; }
    else { throw std::runtime_error("The text is not valid UTF-8."); }

    const auto available = text.size() - offset;
    for (std::size_t byte = 1; byte < width && byte < available; ++byte) {
        const auto next = static_cast<unsigned char>(text[offset + byte]);
        if ((next & 0xC0) != 0x80 ||
            (byte == 1 && ((first == 0xE0 && next < 0xA0) ||
                           (first == 0xED && next > 0x9F) ||
                           (first == 0xF0 && next < 0x90) ||
                           (first == 0xF4 && next > 0x8F)))) {
            throw std::runtime_error("The text is not valid UTF-8.");
        }
        codepoint = (codepoint << 6) | (next & 0x3F);
    }
    if (available < width) return std::nullopt;
    offset += width;
    return codepoint;
}

// Return a complete prefix, resuming at a previously verified scalar boundary.
// Generated tokens can split a scalar; its bytes wait for the next token.
inline std::size_t utf8Prefix(std::string_view text, bool *japanese = nullptr,
                              std::size_t offset = 0) {
    if (offset > text.size()) throw std::out_of_range("UTF-8 offset is beyond the text.");
    while (offset < text.size()) {
        const auto codepoint = decodeUtf8(text, offset);
        if (!codepoint) break;
        const auto c = *codepoint;
        if (japanese && ((c >= 0x3040 && c <= 0x30FF) ||
                         (c >= 0x31F0 && c <= 0x31FF) ||
                         (c >= 0xFF66 && c <= 0xFF9F) ||
                         (c >= 0x3400 && c <= 0x4DBF) ||
                         (c >= 0x4E00 && c <= 0x9FFF) ||
                         (c >= 0xF900 && c <= 0xFAFF) ||
                         (c >= 0x20000 && c <= 0x323AF) ||
                         (c >= 0x3005 && c <= 0x3007))) {
            *japanese = true;
        }
    }
    return offset;
}

}
