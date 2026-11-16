#include "EngineEventMailbox.h"
#include <atomic>
#include <cstdlib>
#include <iostream>
#include <thread>

using bawan::EngineEvent;
using Kind = EngineEvent::Kind;
static void require(bool value) { if (!value) std::abort(); }

static void requireEvents(const std::vector<EngineEvent> &actual,
                          const std::vector<EngineEvent> &expected) {
    require(actual.size() == expected.size());
    for (std::size_t i = 0; i < expected.size(); ++i) {
        require(actual[i].kind == expected[i].kind &&
                actual[i].requestId == expected[i].requestId &&
                actual[i].text == expected[i].text &&
                actual[i].truncated == expected[i].truncated &&
                actual[i].direction == expected[i].direction);
    }
}

int main() {
    bawan::EngineEventMailbox mailbox;
    // Simulate a blocked UI while all 4,096 generated tokens arrive.
    for (std::size_t n = 1; n <= 4096; ++n) {
        require(mailbox.push({Kind::Text, 1, std::string(n * 4, 'x'), false,
                             bawan::Direction::EnglishToJapanese}) == (n == 1));
    }
    requireEvents(mailbox.drain(), {{Kind::Text, 1, std::string(16384, 'x'), false,
                                    bawan::Direction::EnglishToJapanese}});

    require(mailbox.push({Kind::Loading, 0, ""}));
    require(!mailbox.push({Kind::Ready, 0, ""}));
    require(!mailbox.push({Kind::Text, 2, "old"}));
    require(!mailbox.push({Kind::Text, 2, "latest"}));
    // Consecutive text from another request must not replace request 2's snapshot.
    require(!mailbox.push({Kind::Text, 3, "next request"}));
    require(!mailbox.push({Kind::Cancelled, 3, ""}));
    // Returning to request 2 must not coalesce across a terminal-event barrier.
    require(!mailbox.push({Kind::Text, 2, "resumed"}));
    require(!mailbox.push({Kind::Complete, 2, "final", true,
                          bawan::Direction::EnglishToJapanese}));
    require(!mailbox.push({Kind::Error, 4, "error"}));
    require(!mailbox.push({Kind::Idle, 0, ""}));
    requireEvents(mailbox.drain(), {
        {Kind::Loading, 0, ""}, {Kind::Ready, 0, ""},
        {Kind::Text, 2, "latest"}, {Kind::Text, 3, "next request"},
        {Kind::Cancelled, 3, ""}, {Kind::Text, 2, "resumed"},
        {Kind::Complete, 2, "final", true, bawan::Direction::EnglishToJapanese},
        {Kind::Error, 4, "error"}, {Kind::Idle, 0, ""},
    });

    // A drain races with the producer: all terminal events arrive once, in order.
    std::atomic<bool> done{false};
    std::atomic<unsigned> scheduled{0};
    std::thread producer([&] {
        for (unsigned n = 1; n <= 10000; ++n) {
            if (mailbox.push({Kind::Text, n, "a"})) ++scheduled;
            if (mailbox.push({Kind::Text, n, "ab"})) ++scheduled;
            if (mailbox.push({Kind::Complete, n, "abc"})) ++scheduled;
        }
        done = true;
    });
    unsigned completed = 0;
    auto consume = [&] {
        for (const auto &event : mailbox.drain()) {
            if (event.kind == Kind::Complete) require(event.requestId == ++completed);
        }
    };
    // Only drain after a real scheduling signal, not unconditional polling.
    while (!done || scheduled.load() != 0) {
        const auto callbacks = scheduled.exchange(0);
        for (unsigned n = 0; n < callbacks; ++n) consume();
        std::this_thread::yield();
    }
    producer.join();
    require(completed == 10000);
    require(mailbox.push({Kind::Text, 10001, "rescheduled"}));
    require(mailbox.drain().size() == 1);
    std::cout << "PASS: snapshot coalescing, event ordering, rescheduling, concurrent drain\n";
}
