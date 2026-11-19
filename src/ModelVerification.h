#import <Foundation/Foundation.h>

#include <atomic>
#include <cstdint>
#include <sys/stat.h>

extern NSString *const ModelPathCollision;

enum class Verification { Valid, Invalid, Failed, Collision, Cancelled };

// Hashes the file unless trustStamp is set and the file still carries the stamp
// of its last successful verification. Returns Cancelled once generation moves
// past expectedGeneration. info receives the file's stat for RemoveInvalidSavedModel.
Verification VerifyModel(NSURL *url, const std::atomic<uint64_t> &generation, uint64_t expectedGeneration,
                         int64_t expectedSize, const char *expectedSHA256, bool trustStamp,
                         struct stat &info, NSString **reason);

// Returns an error message, or nil when the path is free or holds a regular file.
NSString *CheckSavedModelPath(NSURL *url, bool *present = nullptr);

// Removes a saved model that failed verification unless it changed since then.
NSString *RemoveInvalidSavedModel(NSURL *url, const struct stat &verified);
