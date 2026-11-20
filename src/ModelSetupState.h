#import <Foundation/Foundation.h>

#include "ModelStoreSnapshot.h"

#include <optional>
#include <variant>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BawanModelSetupPhase) {
    BawanModelSetupNeedsDownload,
    BawanModelSetupPreparing,
    BawanModelSetupDownloading,
    BawanModelSetupPaused,
    BawanModelSetupResumableFailure,
    BawanModelSetupReady,
    BawanModelSetupFailed
};

static NSString *const BawanModelNeedsSetupStatus = @"Prepare the translation model to get started.";
static NSString *const BawanModelLoadingStatus = @"Loading the model…";
static NSString *const BawanModelFailedStatus = @"The model could not be prepared. Please try again.";
static NSString *const BawanModelReadyStatus = @"Ready to translate · On-device processing";

struct BawanEngineIdle {};
struct BawanEngineLoading {};
struct BawanEngineFailed {
    NSString *_Nullable message;
};
using BawanEngine = std::variant<BawanEngineIdle, BawanEngineLoading, BawanEngineFailed>;

struct BawanModelReady {
    NSURL *url;
    BawanEngine engine;
};
using BawanModelSetup =
    std::variant<ModelIdle, ModelDownloading, ModelPaused, ModelVerifying, BawanModelReady, ModelFailed>;

inline BawanModelSetup BawanModelSetupFor(const ModelStoreSnapshot &file) {
    return std::visit([](const auto &state) -> BawanModelSetup {
        if constexpr (std::is_same_v<std::decay_t<decltype(state)>, ModelReady>)
            return BawanModelReady{state.url, BawanEngineIdle{}};
        else
            return state;
    }, file);
}

inline NSString *BawanModelIssueText(ModelIssue issue) {
    switch (issue) {
        case ModelIssue::FolderUnavailable: return @"Unable to create the model folder.";
        case ModelIssue::PathOccupied:
            return @"The model file path is occupied by a folder or another item. Move it out of the model folder and try again.";
        case ModelIssue::PathUncheckable:
            return @"Unable to check the saved model path. Check the folder permissions and try again.";
        case ModelIssue::AnotherInstancePreparing:
            return @"Another Bawan instance is preparing the model. Pause it or wait for it to finish, then try again.";
        case ModelIssue::LockUnavailable:
            return @"Unable to lock the model download. Check the folder permissions and try again.";
        case ModelIssue::OldPartialUnremovable:
            return @"Unable to remove the old partial download. Check for conflicting items or folder permissions and try again.";
        case ModelIssue::InvalidPartialUnremovable:
            return @"Unable to remove the invalid partial download. Check the folder permissions and try again.";
        case ModelIssue::PartialRestartFailed:
            return @"Unable to restart the partial download. Check the folder permissions and try again.";
        case ModelIssue::InsecureRedirect:
            return @"The server redirected the model download to an insecure address. Please try again.";
        case ModelIssue::IncompatibleResponse:
            return @"The server returned an incompatible model download. The partial download was discarded. Please try again.";
        case ModelIssue::PartialUnopenable:
            return @"Unable to open the partial download. Check disk space and folder permissions, then try again.";
        case ModelIssue::DownloadUnsaved: return @"Unable to save the model download. Please try again.";
        case ModelIssue::ProgressUnsaved:
            return @"Unable to save download progress. Check disk space and folder permissions, then try again.";
        case ModelIssue::DownloadWrongSize:
            return @"The model download has an incorrect size. The partial download was discarded. Please try again.";
        case ModelIssue::DiskFull: return @"Unable to save the model download. Check free disk space and try again.";
        case ModelIssue::SavedModelChanged: return @"The saved model changed during verification. Please try again.";
        case ModelIssue::InvalidModelUnremovable:
            return @"Unable to remove the invalid model file. Check the folder permissions.";
        case ModelIssue::InstallFailed:
            return @"Unable to save the verified model. Check the folder permissions and try again.";
    }
}

inline NSString *BawanModelCheckText(ModelCheckFailed check) {
    NSString *problem = nil;
    switch (check.issue) {
        case ModelCheckIssue::Unopenable: problem = @"Unable to open the model file. Check the folder permissions."; break;
        case ModelCheckIssue::SizeUnreadable: problem = @"Unable to check the model file size."; break;
        case ModelCheckIssue::WrongSize: problem = @"The model file size is incorrect."; break;
        case ModelCheckIssue::Unreadable: problem = @"Unable to read the model file."; break;
        case ModelCheckIssue::HashMismatch: problem = @"The model file failed SHA256 verification."; break;
    }
    NSString *cleanup = check.file == ModelFileKind::Download ? @" The partial download was discarded." : @"";
    return [NSString stringWithFormat:@"%@%@ Please try again to download the model.", problem, cleanup];
}

inline NSString *BawanModelFailureText(const ModelFailed &failed) {
    NSString *next = failed.resumeProgress ? @"Resume to continue the download." : @"Please try again.";
    if (auto *issue = std::get_if<ModelIssue>(&failed.failure)) return BawanModelIssueText(*issue);
    if (auto *check = std::get_if<ModelCheckFailed>(&failed.failure)) return BawanModelCheckText(*check);
    if (auto *http = std::get_if<ModelHTTPFailed>(&failed.failure))
        return [NSString stringWithFormat:@"Model download failed (HTTP %ld). %@", http->status, next];
    NSString *cause = std::get<ModelInterrupted>(failed.failure).systemMessage ?: @"The server sent an incomplete file.";
    return [NSString stringWithFormat:@"Model download interrupted. %@ %@", cause, next];
}

inline NSString *BawanModelDownloadText(const ModelDownloading &downloading) {
    switch (downloading.stage) {
        case ModelDownloadStage::Starting: return @"Downloading the model…";
        case ModelDownloadStage::Resuming: return @"Resuming the model download…";
        case ModelDownloadStage::Restarted: return @"The server restarted the download from the beginning.";
        case ModelDownloadStage::Receiving: break;
    }
    return [NSString stringWithFormat:@"Downloading the model… %.0f%%", downloading.progress * 100];
}

struct BawanModelSetupView {
    BawanModelSetupPhase phase;
    NSString *message;
    std::optional<double> progress;
};

inline BawanModelSetupView BawanPresentModelSetup(const BawanModelSetup &setup) {
    if (std::holds_alternative<ModelIdle>(setup)) return {BawanModelSetupNeedsDownload, BawanModelNeedsSetupStatus, 0};
    if (auto *downloading = std::get_if<ModelDownloading>(&setup))
        return {BawanModelSetupDownloading, BawanModelDownloadText(*downloading), downloading->progress};
    if (auto *paused = std::get_if<ModelPaused>(&setup))
        return {BawanModelSetupPaused, paused->resumable ? @"Model download paused. Resume to continue."
                                                         : @"Model download paused. Resume to restart the download.",
                paused->progress};
    if (auto *verifying = std::get_if<ModelVerifying>(&setup)) {
        if (verifying->file == ModelFileKind::Saved) return {BawanModelSetupPreparing, @"Checking the saved model…", 0};
        return {BawanModelSetupPreparing, @"Download complete. Verifying SHA256…", 1};
    }
    if (auto *failed = std::get_if<ModelFailed>(&setup))
        return {failed->resumeProgress ? BawanModelSetupResumableFailure : BawanModelSetupFailed,
                BawanModelFailureText(*failed), failed->resumeProgress.value_or(0)};
    const BawanEngine &engine = std::get<BawanModelReady>(setup).engine;
    if (std::holds_alternative<BawanEngineLoading>(engine))
        return {BawanModelSetupPreparing, BawanModelLoadingStatus, std::nullopt};
    if (auto *engineFailed = std::get_if<BawanEngineFailed>(&engine))
        return {BawanModelSetupFailed, engineFailed->message.length ? engineFailed->message : BawanModelFailedStatus, 1};
    return {BawanModelSetupReady, BawanModelReadyStatus, 1};
}

class BawanModelState {
public:
    void fileChanged(const ModelStoreSnapshot &file) { setup_ = BawanModelSetupFor(file); }

    void engineLoading() { setEngine(BawanEngineLoading{}); }
    void engineIdle() { setEngine(BawanEngineIdle{}); }
    void engineFailed(NSString *_Nullable message) { setEngine(BawanEngineFailed{message}); }
    void stopLoading() {
        if (auto *ready = std::get_if<BawanModelReady>(&setup_);
            ready && std::holds_alternative<BawanEngineLoading>(ready->engine))
            ready->engine = BawanEngineIdle{};
    }

    const BawanModelSetup &setup() const { return setup_; }
    NSURL *_Nullable url() const {
        auto *ready = std::get_if<BawanModelReady>(&setup_);
        return ready ? ready->url : nil;
    }
    bool hasVerifiedFile() const { return std::holds_alternative<BawanModelReady>(setup_); }
    bool setupNotStarted() const { return std::holds_alternative<ModelIdle>(setup_); }
    bool engineHasFailed() const {
        auto *ready = std::get_if<BawanModelReady>(&setup_);
        return ready && std::holds_alternative<BawanEngineFailed>(ready->engine);
    }
    bool failed() const { return std::holds_alternative<ModelFailed>(setup_) || engineHasFailed(); }
    bool canEnterTranslator() const { return hasVerifiedFile() && !engineHasFailed(); }
    bool canFinishSetup() const { return !setupNotStarted() && !failed(); }

    BawanModelSetupView view() const { return BawanPresentModelSetup(setup_); }
    BawanModelSetupPhase phase() const { return view().phase; }
    NSString *message() const { return view().message; }
    std::optional<double> progress() const { return view().progress; }

private:
    void setEngine(BawanEngine engine) {
        if (auto *ready = std::get_if<BawanModelReady>(&setup_)) ready->engine = engine;
    }

    BawanModelSetup setup_ = ModelIdle{};
};

NS_ASSUME_NONNULL_END
