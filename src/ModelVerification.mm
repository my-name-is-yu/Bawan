#import "ModelVerification.h"

#include <CommonCrypto/CommonDigest.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <string>
#include <sys/xattr.h>
#include <unistd.h>

NSString *const ModelPathCollision =
    @"The model file path is occupied by a folder or another item. Move it out of the model folder and try again.";

static const char VerifiedAttribute[] = "local.bawan.verified-sha256";

NSString *CheckSavedModelPath(NSURL *url, bool *present) {
    struct stat info {};
    const bool exists = lstat(url.fileSystemRepresentation, &info) == 0;
    if (present) *present = exists;
    if (exists) return S_ISREG(info.st_mode) ? nil : ModelPathCollision;
    return errno == ENOENT ? nil : @"Unable to check the saved model path. Check the folder permissions and try again.";
}

NSString *RemoveInvalidSavedModel(NSURL *url, const struct stat &verified) {
    const char *path = url.fileSystemRepresentation;
    struct stat current {};
    if (lstat(path, &current) == 0) {
        if (!S_ISREG(current.st_mode)) return ModelPathCollision;
        if (current.st_dev != verified.st_dev || current.st_ino != verified.st_ino ||
            current.st_size != verified.st_size || current.st_mtimespec.tv_sec != verified.st_mtimespec.tv_sec ||
            current.st_mtimespec.tv_nsec != verified.st_mtimespec.tv_nsec) {
            return @"The saved model changed during verification. Please try again.";
        }
        // The path could have changed since lstat. Unlink never recurses into a directory.
        if (unlink(path) == 0) return nil;
    }
    if (errno == ENOENT) return nil;
    return CheckSavedModelPath(url) ?: @"Unable to remove the invalid model file. Check the folder permissions.";
}

static std::string VerificationStamp(const struct stat &info, const char *expectedSHA256) {
    char stamp[160];
    std::snprintf(stamp, sizeof(stamp), "1 %s %lld %llu %ld.%09ld", expectedSHA256,
        static_cast<long long>(info.st_size), static_cast<unsigned long long>(info.st_ino),
        static_cast<long>(info.st_mtimespec.tv_sec), static_cast<long>(info.st_mtimespec.tv_nsec));
    return stamp;
}

static bool HasVerificationStamp(int descriptor, const std::string &stamp) {
    char saved[160];
    const ssize_t length = fgetxattr(descriptor, VerifiedAttribute, saved, sizeof(saved), 0, 0);
    return length == static_cast<ssize_t>(stamp.size()) && std::memcmp(saved, stamp.data(), stamp.size()) == 0;
}

Verification VerifyModel(NSURL *url, const std::atomic<uint64_t> &generation,
                         uint64_t expectedGeneration, int64_t expectedSize,
                         const char *expectedSHA256, bool trustStamp, struct stat &info, NSString **reason) {
    const int descriptor = open(url.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (descriptor < 0) {
        if (errno == ELOOP) return Verification::Collision;
        *reason = @"Unable to open the model file. Check the folder permissions.";
        return Verification::Failed;
    }
    std::unique_ptr<FILE, decltype(&std::fclose)> file(fdopen(descriptor, "rb"), &std::fclose);
    if (!file) {
        close(descriptor);
        *reason = @"Unable to open the model file. Check the folder permissions.";
        return Verification::Failed;
    }
    if (fstat(descriptor, &info) != 0) {
        *reason = @"Unable to check the model file size.";
        return Verification::Failed;
    }
    if (!S_ISREG(info.st_mode)) return Verification::Collision;
    if (info.st_size != expectedSize) {
        *reason = @"The model file size is incorrect.";
        return Verification::Invalid;
    }
    const std::string stamp = VerificationStamp(info, expectedSHA256);
    if (trustStamp && HasVerificationStamp(fileno(file.get()), stamp)) {
        return generation.load() == expectedGeneration ? Verification::Valid : Verification::Cancelled;
    }

    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    unsigned char buffer[64 * 1024];
    size_t total = 0;
    for (;;) {
        if (generation.load() != expectedGeneration) return Verification::Cancelled;
        const size_t count = std::fread(buffer, 1, sizeof(buffer), file.get());
        if (count) {
            CC_SHA256_Update(&hash, buffer, static_cast<CC_LONG>(count));
            total += count;
        }
        if (count < sizeof(buffer)) {
            if (std::ferror(file.get())) {
                *reason = @"Unable to read the model file.";
                return Verification::Failed;
            }
            break;
        }
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &hash);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    constexpr char digits[] = "0123456789abcdef";
    for (size_t i = 0; i < sizeof(digest); ++i) {
        hex[i * 2] = digits[digest[i] >> 4];
        hex[i * 2 + 1] = digits[digest[i] & 0x0f];
    }
    hex[sizeof(hex) - 1] = '\0';
    if (total != static_cast<size_t>(expectedSize) || std::strcmp(hex, expectedSHA256) != 0) {
        *reason = @"The model file failed SHA256 verification.";
        fremovexattr(fileno(file.get()), VerifiedAttribute, 0);
        return Verification::Invalid;
    }
    struct stat after {};
    if (fstat(fileno(file.get()), &after) == 0 && VerificationStamp(after, expectedSHA256) == stamp) {
        fsetxattr(fileno(file.get()), VerifiedAttribute, stamp.data(), stamp.size(), 0, 0);
    }
    return generation.load() == expectedGeneration ? Verification::Valid : Verification::Cancelled;
}
