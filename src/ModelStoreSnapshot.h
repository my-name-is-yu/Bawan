#pragma once

#import <Foundation/Foundation.h>

#include <optional>
#include <variant>

NS_ASSUME_NONNULL_BEGIN

enum class ModelIssue {
    FolderUnavailable,
    PathOccupied,
    PathUncheckable,
    AnotherInstancePreparing,
    LockUnavailable,
    OldPartialUnremovable,
    InvalidPartialUnremovable,
    PartialRestartFailed,
    InsecureRedirect,
    IncompatibleResponse,
    PartialUnopenable,
    DownloadUnsaved,
    ProgressUnsaved,
    DownloadWrongSize,
    DiskFull,
    SavedModelChanged,
    InvalidModelUnremovable,
    InstallFailed
};

enum class ModelFileKind { Saved, Download };
enum class ModelCheckIssue { Unopenable, SizeUnreadable, WrongSize, Unreadable, HashMismatch };

struct ModelCheckFailed {
    ModelCheckIssue issue;
    ModelFileKind file;
};
struct ModelHTTPFailed {
    long status;
};
struct ModelInterrupted {
    NSString *_Nullable systemMessage;
};
using ModelFailure = std::variant<ModelIssue, ModelCheckFailed, ModelHTTPFailed, ModelInterrupted>;

enum class ModelDownloadStage { Starting, Resuming, Restarted, Receiving };

struct ModelIdle {};
struct ModelDownloading {
    double progress;
    ModelDownloadStage stage;
};
struct ModelPaused {
    double progress;
    bool resumable;
};
struct ModelVerifying {
    ModelFileKind file;
};
struct ModelReady {
    NSURL *url;
};
struct ModelFailed {
    ModelFailure failure;
    std::optional<double> resumeProgress = std::nullopt;
};

using ModelStoreSnapshot =
    std::variant<ModelIdle, ModelDownloading, ModelPaused, ModelVerifying, ModelReady, ModelFailed>;

NS_ASSUME_NONNULL_END
