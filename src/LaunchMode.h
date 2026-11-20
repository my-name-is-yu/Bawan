#import <Foundation/Foundation.h>

#include <variant>

namespace bawan {

struct InteractiveLaunch {};
struct MemoryProbeLaunch { NSString *directory; };
using LaunchMode = std::variant<InteractiveLaunch, MemoryProbeLaunch>;

inline LaunchMode LaunchModeFromEnvironment(NSDictionary<NSString *, NSString *> *environment) {
    NSString *directory = environment[@"BAWAN_MEMORY_PROBE"];
    if (directory.length) return MemoryProbeLaunch{[directory copy]};
    return InteractiveLaunch{};
}

}
