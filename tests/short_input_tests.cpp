#include "TranslationPrompt.h"

#include <cstdlib>
#include <iostream>
#include <string_view>

int main() {
    struct Case { std::string_view text; std::size_t words; };
    const Case cases[] = {
        {"serendipitous", 1}, {"once in a blue moon", 5},
        {"Please do not leave yet.", 5}, {"Please do not leave just yet.", 0},
        {"one,two,three,four,five", 5}, {"one,two,three,four,five,six", 0},
        {"  one\ttwo\nthree\r\nfour five  ", 5}, {"one\ttwo\nthree four five six", 0},
        {"I can't do that yet.", 5}, {u8"I can’t do that yet.", 5},
        {"well-known state-of-the-art tools are useful", 5},
        {u8"well‐known state‑of‑the‑art tools are useful", 5},
        {"'one' 'two' 'three' 'four' 'five'", 5},
        {"one--two--three--four--five--six", 0},
        {u8"“one” ‘two’ three—four–five", 5}, {u8"one—two—three—four—five—six", 0},
        {u8"one\u00a0two\u2009three\u202ffour\u3000five", 5},
        {u8"one\u00a0two\u2009three\u202ffour\u3000five six", 0},
        {u8"one…two…three…four…five…six", 0}, {"I have 1 2 3", 5},
        {"I have 1 2 3 4", 0}, {"123 456", 0}, {"", 0}, {" \t\r\n", 0},
        {"--- '?!'", 0}, {u8"東京", 0}, {u8"Hello 東京", 0}, {u8"東京 Hello", 0},
        {u8"café", 0}, {u8"naïve person", 0}, {u8"Hello 😊", 0},
        {std::string_view("Hi\0there", 8), 0}, {"Hello\x7Fworld", 0},
        {"Hello \xE2\x80", 0}, {"Hello \xFF", 0},
        {"Apple", 1}, {"OpenAI GPT-4", 2}, {"don't", 1}, {"state-of-the-art", 1},
    };
    for (const auto & test : cases) {
        if (lore::shortEnglishWordCount(test.text) != test.words) {
            std::cerr << "Incorrect short-input word count: " << test.text << '\n';
            return EXIT_FAILURE;
        }
    }
    const std::string ordinary = "<|plamo:tag|>dataset<|plamo:msg|>translation<|plamo:tag|>input<|plamo:msg|>";
    if (lore::detail::promptPrefix({}) != ordinary ||
        lore::detail::promptPrefix(lore::detail::productionPrompt("one two three four five six", false)) != ordinary ||
        lore::detail::promptPrefix(lore::detail::productionPrompt(u8"日本語", true)) != ordinary ||
        lore::detail::promptPrefix(lore::detail::productionPrompt("Hello", true)) != ordinary ||
        lore::detail::promptPrefix(lore::detail::productionPrompt(u8"Hello 日本語", false)) != ordinary) {
        std::cerr << "An out-of-scope request changed its prompt\n";
        return EXIT_FAILURE;
    }
    const auto single = lore::detail::productionPrompt("ephemeral", false);
    const auto phrase = lore::detail::productionPrompt("on the fence", false);
    if (!single.sourceEnglish || !single.context.empty() || !single.examples.empty() ||
        phrase.sourceEnglish || phrase.context != "英語から日本語への翻訳です。" || !phrase.examples.empty()) {
        std::cerr << "The frozen short-input policy changed\n";
        return EXIT_FAILURE;
    }
    std::cout << "PASS: " << std::size(cases) << " word boundaries and ordinary-prompt preservation\n";
}
