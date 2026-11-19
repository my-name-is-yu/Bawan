#include "EngineEventMailbox.h"
#include "EngineEventChecks.h"
#include <atomic>
#include <cstdlib>
#include <iostream>
#include <thread>

using bawan::EngineEvent;
using namespace bawan::engine;
using bawan::Direction;
static void require(bool value) { if (!value) std::abort(); }

static Progress progress(std::uint64_t id, std::string text) {
    return {id, std::move(text), Direction::EnglishToJapanese};
}

static void requireProgress(const EngineEvent &event, std::uint64_t id, const std::string &text) {
    const auto *snapshot = std::get_if<Progress>(&event);
    require(snapshot && snapshot->requestId == id && snapshot->textSoFar == text &&
            snapshot->direction == Direction::EnglishToJapanese);
}

int main() {
    bawan::EngineEventMailbox mailbox;
    for (std::size_t n = 1; n <= 4096; ++n) {
        require(mailbox.push(progress(1, std::string(n * 4, 'x'))) == (n == 1));
    }
    const auto burst = mailbox.drain();
    require(burst.size() == 1);
    requireProgress(burst.front(), 1, std::string(16384, 'x'));

    require(mailbox.push(Lifecycle{Loading{}}));
    require(!mailbox.push(Lifecycle{Ready{}}));
    require(!mailbox.push(progress(2, "old")));
    require(!mailbox.push(progress(2, "latest")));
    require(!mailbox.push(progress(3, "next request")));
    require(!mailbox.push(Finished{3, Cancelled{}}));
    require(!mailbox.push(progress(2, "resumed")));
    require(!mailbox.push(Finished{2, Complete{"final", true, Direction::EnglishToJapanese}}));
    require(!mailbox.push(Finished{4, Error{"error"}}));
    require(!mailbox.push(Lifecycle{Idle{}}));
    const auto events = mailbox.drain();
    require(events.size() == 9);
    require(bawan::test::lifecycle<Loading>(events[0]));
    require(bawan::test::lifecycle<Ready>(events[1]));
    requireProgress(events[2], 2, "latest");
    requireProgress(events[3], 3, "next request");
    require(bawan::test::outcome<Cancelled>(events[4]) && std::get<Finished>(events[4]).requestId == 3);
    requireProgress(events[5], 2, "resumed");
    const auto *complete = bawan::test::outcome<Complete>(events[6]);
    require(complete && std::get<Finished>(events[6]).requestId == 2 && complete->text == "final" &&
            complete->truncated && complete->direction == Direction::EnglishToJapanese);
    const auto *error = bawan::test::outcome<Error>(events[7]);
    require(error && std::get<Finished>(events[7]).requestId == 4 && error->message == "error");
    require(bawan::test::lifecycle<Idle>(events[8]));

    std::atomic<bool> done{false};
    std::atomic<unsigned> scheduled{0};
    std::thread producer([&] {
        for (unsigned n = 1; n <= 10000; ++n) {
            if (mailbox.push(progress(n, "a"))) ++scheduled;
            if (mailbox.push(progress(n, "ab"))) ++scheduled;
            if (mailbox.push(Finished{n, Complete{"abc", false, Direction::EnglishToJapanese}})) ++scheduled;
        }
        done = true;
    });
    unsigned completed = 0;
    auto consume = [&] {
        for (const auto &event : mailbox.drain()) {
            if (const auto *finished = std::get_if<Finished>(&event)) {
                require(std::holds_alternative<Complete>(finished->outcome) && finished->requestId == ++completed);
            }
        }
    };
    while (!done || scheduled.load() != 0) {
        const auto callbacks = scheduled.exchange(0);
        for (unsigned n = 0; n < callbacks; ++n) consume();
        std::this_thread::yield();
    }
    producer.join();
    require(completed == 10000);
    require(mailbox.push(progress(10001, "rescheduled")));
    require(mailbox.drain().size() == 1);
    std::cout << "PASS: snapshot coalescing, event ordering, rescheduling, concurrent drain\n";
}
