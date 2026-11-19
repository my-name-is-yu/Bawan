#include "ModelDownload.h"

#include <cstdlib>
#include <iostream>

using bawan::DownloadResponse;

static void require(bool condition, const char *message) {
    if (condition) return;
    std::cerr << "FAIL: " << message << '\n';
    std::exit(1);
}

static void testValidators() {
    for (const auto tag : {"\"revision-1\"", "\"\"", "\"!#$%&'()*+,-./:;<=>?@[]^_`{|}~\""}) {
        require(bawan::isStrongModelETag(tag), "quoted opaque ETags can identify a resumable representation");
    }
    for (const auto tag : {"", "revision-1", "W/\"revision-1\"", "w/\"revision-1\"", "\"",
            "\"a\"b\"", "\"has space\"", "\"tab\t\"", "\"line\n\"", "\"delete\x7f\"", " \"revision-1\""}) {
        require(!bawan::isStrongModelETag(tag), "weak or malformed ETags must not be sent as If-Range validators");
    }
}

static void testResponses() {
    struct Case {
        int status;
        std::int64_t offset;
        const char *range;
        const char *saved;
        const char *current;
        std::int64_t length;
        DownloadResponse expected;
        const char *message;
    };
    const Case cases[] = {
        {200, 0, "", "", "\"v1\"", 100, DownloadResponse::Restart,
            "an initial full representation starts a fresh file"},
        {200, 40, "", "\"v1\"", "\"v1\"", 100, DownloadResponse::Restart,
            "a server ignoring Range replaces the partial instead of appending"},
        {200, 40, "", "\"v1\"", "\"v2\"", 100, DownloadResponse::Restart,
            "If-Range representation changes replace the partial"},
        {200, 40, "", "\"v1\"", "", -1, DownloadResponse::Restart,
            "a chunked full representation can restart and undergo final hash verification"},
        {200, 0, "", "", "", 99, DownloadResponse::Reject,
            "a known incorrect full size cannot become a resumable model"},
        {206, 40, "bytes 40-99/100", "\"v1\"", "\"v1\"", 60, DownloadResponse::Append,
            "a validated suffix continues at exactly the saved byte offset"},
        {206, 40, "bytes 40-99/100", "\"v1\"", "\"v1\"", -1, DownloadResponse::Append,
            "a chunked suffix is bounded by its validated Content-Range"},
        {206, 0, "bytes 0-99/100", "", "", 100, DownloadResponse::Append,
            "an unsolicited complete 206 is safe from offset zero"},
        {206, 40, "bytes 40-99/100", "\"v1\"", "\"v2\"", 60, DownloadResponse::Reject,
            "a changed ETag on a suffix cannot mix two representations"},
        {206, 40, "bytes 40-99/100", "\"v1\"", "", 60, DownloadResponse::Reject,
            "a suffix without its expected validator cannot be appended"},
        {206, 40, "bytes 40-99/100", "W/\"v1\"", "W/\"v1\"", 60, DownloadResponse::Reject,
            "a weak validator cannot establish suffix identity"},
        {206, 40, "bytes 40-99/100", "", "", 60, DownloadResponse::Reject,
            "a persisted suffix needs a strong representation validator"},
        {206, 40, "bytes 41-99/100", "\"v1\"", "\"v1\"", 59, DownloadResponse::Reject,
            "a suffix beginning after the requested offset would leave a gap"},
        {206, 40, "bytes 39-99/100", "\"v1\"", "\"v1\"", 61, DownloadResponse::Reject,
            "a suffix beginning before the requested offset would duplicate bytes"},
        {206, 40, "bytes 40-98/100", "\"v1\"", "\"v1\"", 59, DownloadResponse::Reject,
            "a truncated range is rejected rather than treated as a completed transfer"},
        {206, 40, "bytes 40-99/101", "\"v1\"", "\"v1\"", 60, DownloadResponse::Reject,
            "a changed total size cannot resume the pinned model"},
        {206, 40, "bytes 40-99/100", "\"v1\"", "\"v1\"", 59, DownloadResponse::Reject,
            "Content-Length must match the validated suffix length"},
        {206, 100, "bytes 100-99/100", "\"v1\"", "\"v1\"", 0, DownloadResponse::Reject,
            "a complete partial must be hashed rather than appended"},
        {416, 40, "bytes */100", "\"v1\"", "\"v1\"", 0, DownloadResponse::RetryFromStart,
            "an unsatisfiable saved range requests a bounded fresh retry"},
        {416, 0, "bytes */100", "", "", 0, DownloadResponse::Reject,
            "an initial 416 cannot create a retry loop"},
        {404, 40, "", "\"v1\"", "", 0, DownloadResponse::Reject,
            "an HTTP failure body never becomes model bytes"},
        {503, 0, "", "", "", -1, DownloadResponse::Reject,
            "a service error cannot be interpreted as a download"},
        {204, 0, "", "", "", 0, DownloadResponse::Reject,
            "other successful statuses are not complete model responses"},
    };
    for (const auto &item : cases) {
        require(bawan::modelDownloadResponse(item.status, item.offset, 100, item.range, item.saved,
            item.current, item.length) == item.expected, item.message);
    }
    for (const auto range : {"", "bytes */100", "bytes -40-99/100", "bytes +40-99/100", "bytes 40-99/*",
            "bytes 40-99/100 trailing", "bytes 40-99/100\n", "bytes 40 -99/100", "bytes 40-99 /100",
            "bytes 40-99/100, bytes 40-99/100", "bytes 9223372036854775808-99/100",
            "bytes 40-9223372036854775808/100", "bytes 40-99/9223372036854775808"}) {
        require(bawan::modelDownloadResponse(206, 40, 100, range, "\"v1\"", "\"v1\"", 60)
            == DownloadResponse::Reject, "malformed, wildcard, multipart or overflowing Content-Range is rejected");
    }
    require(bawan::modelDownloadResponse(200, -1, 100, "", "", "", 100) == DownloadResponse::Reject,
        "negative saved offsets are rejected");
    require(bawan::modelDownloadResponse(200, 101, 100, "", "", "", 100) == DownloadResponse::Reject,
        "oversized saved offsets are rejected");
    require(bawan::modelDownloadResponse(200, 0, 0, "", "", "", 0) == DownloadResponse::Reject,
        "an empty model expectation is invalid");
    require(bawan::modelDownloadResponse(200, 0, 100, "", "", "", -2) == DownloadResponse::Reject,
        "only the explicit unknown Content-Length sentinel is accepted");
}

int main() {
    testValidators();
    testResponses();
    std::cout << "PASS: model download response policy\n";
}
