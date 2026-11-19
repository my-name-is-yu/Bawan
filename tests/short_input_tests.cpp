#include "ShortInput.h"

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
        {u8"café", 1}, {u8"naïve person", 2}, {u8"Hello 😊", 0},
        {u8"Café déjà vu feels familiar.", 5}, {u8"Café déjà vu feels very familiar.", 0},
        {u8"Æsir œuvre Łódź ǅungla ḃook", 5},
        {u8"cafe\u0301", 1}, {u8"nai\u0308ve person", 2},
        {u8"cafe\u0301\u0304-style", 1}, {u8"cafés’ menus", 2},
        {u8"café-au-lait", 1}, {u8"café‑au‑lait", 1},
        {u8"café--naïve--résumé--touché--élite--façade", 0},
        {u8"cafe\u0301 one two three four", 5}, {u8"cafe\u0301 one two three four five", 0},
        {u8"\u0301cafe", 0}, {u8"cafe \u0301", 0}, {u8"cafe-\u0301word", 0}, {u8"cafe1\u0301", 0},
        {u8"«café» · naïve • résumé", 3}, {u8"£5 café €2", 3},
        {u8"one•two•three•four•five•six", 0}, {u8"one×two÷three±four·five€six", 0},
        {u8"one\u1680two\u205fthree", 3}, {u8"©®™€×÷±°", 0},
        {u8"Hello こんにちは", 0}, {u8"Hello カフェ", 0}, {u8"café ｶﾌｪ", 0},
        {u8"café 々", 0}, {u8"café 𠀀", 0}, {u8"café Ελληνικά", 0},
        {u8"café русский", 0}, {u8"café 한국어", 0}, {u8"café العربية", 0},
        {u8"café １２３", 0}, {u8"café\u200bword", 0}, {u8"café\u202eword", 0},
        {u8"café\ufeffword", 0}, {"Hello\xC2\x85world", 0},
        {std::string_view("Hi\0there", 8), 0}, {"Hello\x7Fworld", 0},
        {"Hello \xE2\x80", 0}, {"Hello \xFF", 0},
        {"Hello \xC0\xAF", 0}, {"Hello \xE0\x80\xAF", 0},
        {"Hello \xED\xA0\x80", 0}, {"Hello \xF4\x90\x80\x80", 0},
        {"Hello \xE2!", 0}, {"Hello \x80", 0}, {"Hello \xF0\x90\x80", 0},
        {"Apple", 1}, {"OpenAI GPT-4", 2}, {"don't", 1}, {"state-of-the-art", 1},
    };
    for (const auto & test : cases) {
        if (bawan::shortEnglishWordCount(test.text) != test.words) {
            std::cerr << "Incorrect short-input word count: " << test.text << '\n';
            return EXIT_FAILURE;
        }
    }
    std::cout << "PASS: " << std::size(cases) << " short-English word boundaries\n";
}
