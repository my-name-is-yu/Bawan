#include "Utf8.h"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <string>
#include <string_view>

namespace {

void require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

void validScalars() {
    struct Case { std::string_view bytes; char32_t scalar; };
    const Case cases[] = {
        {std::string_view("\0", 1), 0}, {"A", U'A'}, {"\x7F", 0x7F},
        {"\xC2\x80", 0x80}, {u8"é", U'é'}, {"\xDF\xBF", 0x7FF},
        {"\xE0\xA0\x80", 0x800}, {u8"あ", U'あ'}, {"\xED\x9F\xBF", 0xD7FF},
        {"\xEE\x80\x80", 0xE000}, {"\xEF\xBF\xBF", 0xFFFF},
        {"\xF0\x90\x80\x80", 0x10000}, {u8"😀", U'😀'},
        {"\xF4\x8F\xBF\xBF", 0x10FFFF},
    };
    for (const auto &test : cases) {
        std::size_t offset = 0;
        const auto scalar = bawan::detail::decodeUtf8(test.bytes, offset);
        require(scalar && *scalar == test.scalar && offset == test.bytes.size(),
                "decode a complete Unicode scalar");
        require(!bawan::detail::decodeUtf8(test.bytes, offset) && offset == test.bytes.size(),
                "decoding at end leaves the offset unchanged");
        require(bawan::detail::utf8Prefix(test.bytes) == test.bytes.size(),
                "complete valid scalar belongs to prefix");
        for (std::size_t size = 1; size < test.bytes.size(); ++size) {
            offset = 0;
            require(!bawan::detail::decodeUtf8(test.bytes.substr(0, size), offset) && offset == 0,
                    "an incomplete scalar waits without consuming bytes");
            require(bawan::detail::utf8Prefix(test.bytes.substr(0, size)) == 0,
                    "prefix does not split an incomplete scalar");
        }
    }
    std::size_t offset = 0;
    require(!bawan::detail::decodeUtf8({}, offset) && bawan::detail::utf8Prefix({}) == 0,
            "empty text has an empty prefix");
}

void invalidSequences() {
    const std::string_view cases[] = {
        "\x80", "\xBF", "\xC0\x80", "\xC1\xBF", // stray/overlong leads
        "\xF5\x80\x80\x80", "\xF8", "\xFC", "\xFE", "\xFF",
        "\xC2!", "\xE2!", "\xE2\x82!", "\xF0!", "\xF0\x90!", "\xF0\x90\x80!",
        "\xE2\xC2\x80", "\xF0\x90\xC2\x80", // non-continuation multibyte leads
        "\xE0\x80", "\xE0\x9F\xBF", "\xF0\x80", "\xF0\x8F\xBF\xBF", // overlong
        "\xED\xA0", "\xED\xA0\x80", "\xED\xBF\xBF", // surrogates
        "\xF4\x90", "\xF4\x90\x80\x80", "\xF4\xBF\xBF\xBF", // outside Unicode
    };
    for (const auto bytes : cases) {
        std::size_t offset = 0;
        bool rejected = false;
        try { (void)bawan::detail::decodeUtf8(bytes, offset); }
        catch (const std::runtime_error &error) {
            rejected = std::string_view(error.what()) == "The text is not valid UTF-8.";
        }
        require(rejected && offset == 0, "invalid scalar is rejected without consuming bytes");
        rejected = false;
        try { (void)bawan::detail::utf8Prefix(std::string("ok") + std::string(bytes)); }
        catch (const std::runtime_error &) { rejected = true; }
        require(rejected, "prefix rejects malformed bytes after valid text");
    }
}

void streamingPrefix() {
    const std::string text = u8"Aéあ😀Z";
    const std::size_t boundaries[] = {0, 1, 1, 3, 3, 3, 6, 6, 6, 6, 10, 11};
    require(text.size() + 1 == std::size(boundaries), "streaming fixture byte count");
    for (std::size_t size = 0; size <= text.size(); ++size) {
        bool japanese = false;
        const auto prefix = bawan::detail::utf8Prefix(std::string_view(text).substr(0, size), &japanese);
        require(prefix == boundaries[size], "every byte cut ends at the last complete scalar");
        require(japanese == (size >= 6), "Japanese is detected only after its scalar completes");
        require(bawan::detail::utf8Prefix(text, &japanese, prefix) == text.size() && japanese,
                "resuming after an incomplete token completes the original text");
    }
    std::string streamed;
    std::size_t prefix = 0;
    bool japanese = false;
    for (std::size_t byte = 0; byte < text.size(); ++byte) {
        streamed += text[byte];
        prefix = bawan::detail::utf8Prefix(streamed, &japanese, prefix);
        require(prefix == boundaries[byte + 1], "single-byte tokens preserve scalar boundaries");
    }
    require(streamed.substr(0, prefix) == text && japanese, "streamed prefix preserves complete text");
    bool rejected = false;
    try { (void)bawan::detail::utf8Prefix(text, nullptr, 2); }
    catch (const std::runtime_error &) { rejected = true; }
    require(rejected, "resuming inside a scalar is rejected");
}

void japaneseDetection() {
    const std::string_view japanese[] = {
        u8"あ", u8"ア", u8"ㇰ", u8"ｱ", u8"㐀", u8"東京", u8"豈", u8"𠀀", u8"々", u8"〆", u8"〇",
    };
    for (const auto text : japanese) {
        bool detected = false;
        require(bawan::detail::utf8Prefix(text, &detected) == text.size() && detected,
                "Japanese script ranges keep automatic direction detection");
    }
    bool detected = false;
    const std::string_view latin = u8"café naïve — 😀";
    require(bawan::detail::utf8Prefix(latin, &detected) == latin.size() && !detected,
            "Latin text and symbols do not trigger Japanese detection");
    detected = true;
    (void)bawan::detail::utf8Prefix(latin, &detected);
    require(detected, "incremental detection retains an earlier Japanese scalar");
}

void invalidOffsets() {
    for (const auto invalid : {std::size_t(2), std::numeric_limits<std::size_t>::max()}) {
        auto offset = invalid;
        bool rejected = false;
        try { (void)bawan::detail::decodeUtf8("A", offset); }
        catch (const std::out_of_range &) { rejected = true; }
        require(rejected && offset == invalid, "decoder rejects an offset beyond the text");
        rejected = false;
        try { (void)bawan::detail::utf8Prefix("A", nullptr, invalid); }
        catch (const std::out_of_range &) { rejected = true; }
        require(rejected, "prefix rejects an offset beyond the text");
    }
}

}

int main() {
    validScalars();
    invalidSequences();
    streamingPrefix();
    japaneseDetection();
    invalidOffsets();
    std::cout << "PASS: UTF-8 scalar validation, streaming prefixes and Japanese detection\n";
}
