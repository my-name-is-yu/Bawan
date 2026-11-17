#pragma once

#include <cstdint>
#include <limits>
#include <string_view>

namespace bawan {

enum class DownloadResponse { Append, Restart, RetryFromStart, Reject };

inline bool isStrongModelETag(std::string_view value) {
    if (value.size() < 2 || value.front() != '"' || value.back() != '"') return false;
    for (std::size_t i = 1; i + 1 < value.size(); ++i) {
        const auto c = static_cast<unsigned char>(value[i]);
        if (c == '"' || c < 0x21 || c == 0x7f) return false;
    }
    return true;
}

namespace detail {

inline bool modelRangeNumber(std::string_view &text, std::int64_t &number) {
    if (text.empty() || text.front() < '0' || text.front() > '9') return false;
    number = 0;
    std::size_t consumed = 0;
    while (consumed < text.size() && text[consumed] >= '0' && text[consumed] <= '9') {
        const int digit = text[consumed] - '0';
        if (number > (std::numeric_limits<std::int64_t>::max() - digit) / 10) return false;
        number = number * 10 + digit;
        ++consumed;
    }
    text.remove_prefix(consumed);
    return true;
}

inline bool modelRangeSeparator(std::string_view &text, char separator) {
    if (text.empty() || text.front() != separator) return false;
    text.remove_prefix(1);
    return true;
}

inline bool modelRangeMatches(std::string_view text, std::int64_t offset, std::int64_t size) {
    constexpr std::string_view prefix = "bytes ";
    if (text.substr(0, prefix.size()) != prefix) return false;
    text.remove_prefix(prefix.size());
    std::int64_t start, end, total;
    return modelRangeNumber(text, start) && modelRangeSeparator(text, '-') &&
        modelRangeNumber(text, end) && modelRangeSeparator(text, '/') &&
        modelRangeNumber(text, total) && text.empty() &&
        start == offset && end == size - 1 && total == size;
}

} // namespace detail

inline DownloadResponse modelDownloadResponse(int status, std::int64_t offset, std::int64_t expectedSize,
                                              std::string_view contentRange, std::string_view savedETag,
                                              std::string_view responseETag, std::int64_t contentLength = -1) {
    if (expectedSize <= 0 || offset < 0 || offset > expectedSize || contentLength < -1)
        return DownloadResponse::Reject;
    if (status == 200) {
        return contentLength == -1 || contentLength == expectedSize
            ? DownloadResponse::Restart : DownloadResponse::Reject;
    }
    if (status == 416 && offset > 0) return DownloadResponse::RetryFromStart;
    if (status != 206 || offset == expectedSize ||
        !detail::modelRangeMatches(contentRange, offset, expectedSize) ||
        (contentLength != -1 && contentLength != expectedSize - offset))
        return DownloadResponse::Reject;
    if (offset > 0 && (!isStrongModelETag(savedETag) || savedETag != responseETag))
        return DownloadResponse::Reject;
    return DownloadResponse::Append;
}

} // namespace bawan
