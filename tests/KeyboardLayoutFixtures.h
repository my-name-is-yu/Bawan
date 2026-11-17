#pragma once

#include "KeyboardLayout.h"

namespace bawan::test {

// Hand-authored logical models for portable tests, not captured macOS layout data.
struct FixtureKey {
    std::uint16_t code;
    char16_t plain;
    char16_t shifted;
};

template <std::size_t N>
KeyboardLayout fixtureLayout(const FixtureKey (&keys)[N]) {
    KeyboardLayout layout;
    for (const auto& key : keys) {
        layout.plain[key.code] = key.plain;
        layout.command[key.code] = key.plain;
        layout.commandShift[key.code] = key.shifted;
    }
    return layout;
}

inline KeyboardLayout qwertyLayout() {
    const FixtureKey keys[] = {
        {0, u'a', u'A'}, {1, u's', u'S'}, {2, u'd', u'D'}, {3, u'f', u'F'},
        {4, u'h', u'H'}, {5, u'g', u'G'}, {6, u'z', u'Z'}, {7, u'x', u'X'},
        {8, u'c', u'C'}, {9, u'v', u'V'}, {11, u'b', u'B'}, {12, u'q', u'Q'},
        {13, u'w', u'W'}, {14, u'e', u'E'}, {15, u'r', u'R'}, {16, u'y', u'Y'},
        {17, u't', u'T'}, {18, u'1', u'!'}, {19, u'2', u'@'}, {20, u'3', u'#'},
        {21, u'4', u'$'}, {22, u'6', u'^'}, {23, u'5', u'%'}, {24, u'=', u'+'},
        {25, u'9', u'('}, {26, u'7', u'&'}, {27, u'-', u'_'}, {28, u'8', u'*'},
        {29, u'0', u')'}, {30, u']', u'}'}, {31, u'o', u'O'}, {32, u'u', u'U'},
        {33, u'[', u'{'}, {34, u'i', u'I'}, {35, u'p', u'P'}, {37, u'l', u'L'},
        {38, u'j', u'J'}, {39, u'\'', u'"'}, {40, u'k', u'K'}, {41, u';', u':'},
        {42, u'\\', u'|'}, {43, u',', u'<'}, {44, u'/', u'?'}, {45, u'n', u'N'},
        {46, u'm', u'M'}, {47, u'.', u'>'}, {49, u' ', u' '}, {50, u'`', u'~'}
    };
    return fixtureLayout(keys);
}

inline KeyboardLayout dvorakLayout() {
    const FixtureKey keys[] = {
        {0, u'a', u'A'}, {1, u'o', u'O'}, {2, u'e', u'E'}, {3, u'u', u'U'},
        {4, u'd', u'D'}, {5, u'i', u'I'}, {6, u';', u':'}, {7, u'q', u'Q'},
        {8, u'j', u'J'}, {9, u'k', u'K'}, {11, u'x', u'X'}, {12, u'\'', u'"'},
        {13, u',', u'<'}, {14, u'.', u'>'}, {15, u'p', u'P'}, {16, u'f', u'F'},
        {17, u'y', u'Y'}, {18, u'1', u'!'}, {19, u'2', u'@'}, {20, u'3', u'#'},
        {21, u'4', u'$'}, {22, u'6', u'^'}, {23, u'5', u'%'}, {24, u']', u'}'},
        {25, u'9', u'('}, {26, u'7', u'&'}, {27, u'[', u'{'}, {28, u'8', u'*'},
        {29, u'0', u')'}, {30, u'=', u'+'}, {31, u'r', u'R'}, {32, u'g', u'G'},
        {33, u'/', u'?'}, {34, u'c', u'C'}, {35, u'l', u'L'}, {37, u'n', u'N'},
        {38, u'h', u'H'}, {39, u'-', u'_'}, {40, u't', u'T'}, {41, u's', u'S'},
        {42, u'\\', u'|'}, {43, u'w', u'W'}, {44, u'z', u'Z'}, {45, u'b', u'B'},
        {46, u'm', u'M'}, {47, u'v', u'V'}, {49, u' ', u' '}, {50, u'`', u'~'}
    };
    return fixtureLayout(keys);
}

inline KeyboardLayout dvorakQwertyCommandLayout() {
    auto layout = dvorakLayout();
    const auto qwerty = qwertyLayout();
    layout.command = qwerty.command;
    layout.commandShift = qwerty.commandShift;
    return layout;
}

}
