#include "CopyGesture.h"
#include <cstdlib>
#include <iostream>

using Gesture = lore::CopyGesture;
using Result = Gesture::Result;

static void require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

static Gesture::Event copy(bool down, std::uint64_t milliseconds,
                           std::int64_t app = 10, bool command = true,
                           bool modifier = false, bool repeat = false) {
    return {down, 8, command, modifier, repeat, app, milliseconds * 1'000'000};
}

int main() {
    Gesture gesture;
    require(gesture.handle(copy(true, 100)) == Result::FirstCopy, "single copy only arms");
    require(gesture.handle(copy(false, 150)) == Result::None, "release does not trigger");
    require(gesture.handle(copy(true, 500)) == Result::DoubleCopy, "400ms inclusive boundary");
    require(gesture.handle(copy(true, 501, 10, true, false, true)) == Result::None, "repeat after trigger does not retrigger");
    gesture.handle(copy(false, 510));
    require(gesture.handle(copy(true, 600)) == Result::FirstCopy, "third press starts another pair");

    gesture.reset();
    gesture.handle(copy(true, 100));
    require(gesture.handle(copy(true, 200)) == Result::None, "two down events without release cannot trigger");
    gesture.handle(copy(true, 250, 10, true, false, true));
    gesture.handle(copy(false, 300));
    require(gesture.handle(copy(true, 350)) == Result::FirstCopy, "long press disarms old pair");

    gesture.reset();
    gesture.handle(copy(true, 100));
    gesture.handle(copy(false, 150, 10, false));
    require(gesture.handle(copy(true, 300)) == Result::DoubleCopy, "command may be released between copies");

    gesture.reset();
    gesture.handle(copy(true, 100));
    gesture.handle(copy(false, 150));
    require(gesture.handle(copy(true, 501)) == Result::FirstCopy, "expired copy starts a new interval");
    gesture.handle(copy(false, 510));
    require(gesture.handle(copy(true, 550)) == Result::DoubleCopy, "new interval remains usable");

    for (bool command : {false, true}) {
        gesture.reset();
        gesture.handle(copy(true, 100));
        gesture.handle(copy(false, 150));
        gesture.handle(copy(true, 200, 10, command, true));
        gesture.handle(copy(false, 220));
        require(gesture.handle(copy(true, 250)) == Result::FirstCopy, "modified or ordinary C disarms");
    }

    gesture.reset();
    gesture.handle(copy(true, 100));
    gesture.handle(copy(false, 150));
    auto other = copy(true, 200);
    other.key = 1;
    gesture.handle(other);
    require(gesture.handle(copy(true, 250)) == Result::FirstCopy, "other key disarms");

    gesture.reset();
    gesture.handle(copy(true, 100));
    gesture.handle(copy(false, 150));
    require(gesture.handle(copy(true, 250, 20)) == Result::FirstCopy, "application change disarms");
    gesture.handle(copy(false, 270, 20));
    require(gesture.handle(copy(true, 300, 20)) == Result::DoubleCopy, "new application pair works");

    gesture.reset();
    gesture.handle(copy(true, 100));
    gesture.handle(copy(false, 150));
    gesture.reset(); // Workspace activation/sleep notification, including A→B→A.
    require(gesture.handle(copy(true, 200)) == Result::FirstCopy, "explicit reset disarms");

    gesture.reset();
    gesture.handle(copy(true, 100));
    gesture.handle(copy(false, 150));
    require(gesture.handle(copy(true, 90)) == Result::FirstCopy, "backwards timestamps cannot trigger");
    std::cout << "Copy gesture tests passed\n";
}
