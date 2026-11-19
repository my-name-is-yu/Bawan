#import <Foundation/Foundation.h>

#include "ModelStoreSnapshot.h"

#include <atomic>
#include <cstdint>
#include <optional>
#include <sys/stat.h>

enum class SavedModelPath { Absent, Present, Occupied, Uncheckable };

SavedModelPath CheckSavedModelPath(NSURL *url);

inline std::optional<ModelIssue> SavedModelPathIssue(SavedModelPath path) {
    if (path == SavedModelPath::Occupied) return ModelIssue::PathOccupied;
    if (path == SavedModelPath::Uncheckable) return ModelIssue::PathUncheckable;
    return std::nullopt;
}

// Removes a saved model that failed verification unless it changed since then.
std::optional<ModelIssue> RemoveInvalidSavedModel(NSURL *url, const struct stat &verified);

enum class VerificationOutcome { Valid, Invalid, Unchecked, Occupied, Cancelled };

struct VerificationResult {
    VerificationOutcome outcome;
    ModelCheckIssue issue = ModelCheckIssue::Unopenable;
    struct stat file {};
};

// Hashes the file unless trustStamp is set and the file still carries the stamp
// of its last successful verification. Cancelled once generation moves past
// expectedGeneration.
VerificationResult VerifyModel(NSURL *url, const std::atomic<uint64_t> &generation,
                               uint64_t expectedGeneration, int64_t expectedSize,
                               const char *expectedSHA256, bool trustStamp);
