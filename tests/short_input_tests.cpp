#include "ShortInput.h"

#include <cstdlib>
#include <iostream>
#include <string_view>

int main() {
    struct Case {
        std::string_view input;
        bool expected;
        const char * description;
    };
    const Case cases[] = {
        {"serendipitous", true, "single word"},
        {"once in a blue moon", true, "five-word idiom"},
        {"Please do not leave yet.", true, "five-word sentence"},
        {"Please do not leave just yet.", false, "six-word sentence"},
        {"one,two,three,four,five", true, "punctuation separates five words"},
        {"one,two,three,four,five,six", false, "punctuation cannot hide sixth word"},
        {"  one\ttwo\nthree\r\nfour five  ", true, "mixed whitespace"},
        {"one\ttwo\nthree four five six", false, "whitespace sixth word"},
        {"I can't do that yet.", true, "straight apostrophe contraction"},
        {u8"I can’t do that yet.", true, "curly apostrophe contraction"},
        {"well-known state-of-the-art tools are useful", true, "hyphen compounds"},
        {u8"well‐known state‑of‑the‑art tools are useful", true, "Unicode hyphens"},
        {"'one' 'two' 'three' 'four' 'five'", true, "outer single quotes"},
        {"one--two--three--four--five--six", false, "double hyphens separate words"},
        {u8"“one” ‘two’ three—four–five", true, "Unicode quotes and dashes"},
        {u8"one—two—three—four—five—six", false, "em dashes separate words"},
        {u8"one\u00a0two\u2009three\u202ffour\u3000five", true, "Unicode spaces"},
        {u8"one\u00a0two\u2009three\u202ffour\u3000five six", false, "Unicode space sixth word"},
        {u8"one…two…three…four…five…six", false, "ellipses separate words"},
        {"I have 1 2 3", true, "numbers count as words alongside English"},
        {"I have 1 2 3 4", false, "numbers contribute to boundary"},
        {"123 456", false, "digits alone are not English"},
        {"", false, "empty input"},
        {" \t\r\n", false, "whitespace alone"},
        {"--- '?!'", false, "punctuation alone"},
        {u8"東京", false, "no ASCII text"},
        {u8"Hello 東京", false, "mixed Japanese"},
        {u8"東京 Hello", false, "leading Japanese"},
        {u8"café", false, "accented word does not count partially"},
        {u8"naïve person", false, "non-ASCII letters bypass short mode"},
        {u8"Hello 😊", false, "unsupported Unicode bypasses short mode"},
        {std::string_view("Hi\0there", 8), false, "embedded null is not a separator"},
        {"Hello\x7Fworld", false, "DEL control is unsupported"},
        {"Hello \xE2\x80", false, "incomplete Unicode punctuation"},
        {"Hello \xFF", false, "invalid UTF-8 byte"},
    };

    for (const auto & test : cases) {
        if (lore::isShortEnglishInput(test.input) != test.expected) {
            std::cerr << "FAIL: " << test.description << '\n';
            return EXIT_FAILURE;
        }
    }
    if (lore::shortEnglishWordCount("ephemeral") != 1 ||
        lore::shortEnglishWordCount("take for granted") != 3 ||
        lore::shortEnglishWordCount("I can't do that yet.") != 5 ||
        lore::shortEnglishWordCount("one two three four five six") != 0) {
        std::cerr << "FAIL: word counts select the correct prompt\n";
        return EXIT_FAILURE;
    }
    std::cout << "Short English input tests passed\n";
}
