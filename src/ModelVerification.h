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

std::optional<ModelIssue> RemoveSavedModelIfUnchanged(NSURL *url, const struct stat &verified);

enum class VerificationOutcome { Valid, Invalid, Unchecked, Occupied, Cancelled };

struct VerificationResult {
    VerificationOutcome outcome;
    ModelCheckIssue issue = ModelCheckIssue::Unopenable;
    struct stat file {};
};

enum class StampUse { TrustUnchanged, Rehash };

VerificationResult VerifyModel(NSURL *url, const std::atomic<uint64_t> &generation,
                               uint64_t expectedGeneration, int64_t expectedSize,
                               const char *expectedSHA256, StampUse stamp);
