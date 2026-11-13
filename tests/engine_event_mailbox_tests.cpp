#include "EngineEventMailbox.h"
#include <atomic>
#include <cstdlib>
#include <iostream>
#include <thread>

using bawan::EngineEvent;
using Kind = EngineEvent::Kind;
static void require(bool value) { if (!value) std::abort(); }

int main() {
    bawan::EngineEventMailbox mailbox;
    // Simulate a blocked UI while all 4,096 generated tokens arrive.
    std::size_t oldBytes = 0;
    for (std::size_t n = 1; n <= 4096; ++n) {
        oldBytes += n * 4;
        require(mailbox.push({Kind::Text, 1, std::string(n * 4, 'x')}) == (n == 1));
    }
    auto events = mailbox.drain();
    require(events.size() == 1 && events[0].text.size() == 16384);
    std::cout << "stalled_ui_old_payload_bytes=" << oldBytes
              << " new_payload_bytes=" << events[0].text.size() << '\n';

    require(mailbox.push({Kind::Loading, 0, ""}));
    require(!mailbox.push({Kind::Ready, 0, ""}));
    require(!mailbox.push({Kind::Text, 2, "old"}));
    require(!mailbox.push({Kind::Text, 2, "latest"}));
    EngineEvent complete{Kind::Complete, 2, "final", true, bawan::Direction::EnglishToJapanese};
    require(!mailbox.push(complete));
    require(!mailbox.push({Kind::Text, 3, "next request"}));
    require(!mailbox.push({Kind::Cancelled, 3, ""}));
    require(!mailbox.push({Kind::Error, 4, "error"}));
    require(!mailbox.push({Kind::Idle, 0, ""}));
    events = mailbox.drain();
    require(events.size() == 8);
    require(events[0].kind == Kind::Loading && events[1].kind == Kind::Ready);
    require(events[2].text == "latest");
    require(events[3].kind == Kind::Complete && events[3].text == "final" &&
            events[3].truncated && events[3].direction == bawan::Direction::EnglishToJapanese);
    require(events[4].requestId == 3 && events[5].kind == Kind::Cancelled &&
            events[6].kind == Kind::Error && events[7].kind == Kind::Idle);

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
