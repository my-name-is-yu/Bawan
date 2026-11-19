#import <Foundation/Foundation.h>

#import "ModelStore.h"

#include <optional>

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
static NSString *const BawanModelCheckingStatus = @"Checking the model…";
static NSString *const BawanModelLoadingStatus = @"Loading the model…";
static NSString *const BawanModelFailedStatus = @"The model could not be prepared. Please try again.";
static NSString *const BawanModelReadyStatus = @"Ready to translate · On-device processing";

enum class BawanEngineState { Idle, Loading, Failed };

inline BawanModelSetupPhase BawanModelSetupPhaseFor(const ModelStoreSnapshot &file, BawanEngineState engine) {
    switch (file.state) {
        case ModelStoreIdle: return BawanModelSetupNeedsDownload;
        case ModelStoreChecking:
        case ModelStoreVerifying: return BawanModelSetupPreparing;
        case ModelStoreDownloading: return BawanModelSetupDownloading;
        case ModelStorePaused: return BawanModelSetupPaused;
        case ModelStoreFailed: return file.resumable ? BawanModelSetupResumableFailure : BawanModelSetupFailed;
        case ModelStoreReady: break;
    }
    switch (engine) {
        case BawanEngineState::Loading: return BawanModelSetupPreparing;
        case BawanEngineState::Failed: return BawanModelSetupFailed;
        case BawanEngineState::Idle: return BawanModelSetupReady;
    }
}

class BawanModelState {
public:
    void fileChanged(const ModelStoreSnapshot &file) {
        file_ = file;
        engine_ = BawanEngineState::Idle;
        engineMessage_ = nil;
    }

    // Engine transitions. They are ignored unless the file is present.
    void engineLoading() { setEngine(BawanEngineState::Loading, nil); }
    void engineIdle() { setEngine(BawanEngineState::Idle, nil); }
    void engineFailed(NSString *message) { setEngine(BawanEngineState::Failed, message); }
    // Cancelling a request stops a load in progress but keeps a reported failure.
    void stopLoading() { if (engine_ == BawanEngineState::Loading) engineIdle(); }

    BawanEngineState engine() const { return engine_; }
    NSURL *url() const { return file_.fileURL; }
    bool hasVerifiedFile() const { return file_.state == ModelStoreReady; }
    bool setupNotStarted() const { return file_.state == ModelStoreIdle; }
    bool failed() const { return file_.state == ModelStoreFailed || engine_ == BawanEngineState::Failed; }
    // Escape/Open Translator can leave setup once the file is verified. A load
    // may still be running, but a reported engine failure needs attention first.
    bool canEnterTranslator() const { return hasVerifiedFile() && engine_ != BawanEngineState::Failed; }
    // The explicit setup footer action may continue while preparation is running.
    bool canFinishSetup() const { return !setupNotStarted() && !failed(); }
    BawanModelSetupPhase phase() const { return BawanModelSetupPhaseFor(file_, engine_); }

    std::optional<double> progress() const {
        if (hasVerifiedFile() && engine_ == BawanEngineState::Loading) return std::nullopt;
        return file_.progress;
    }

    NSString *message() const {
        NSString *message = file_.message.length ? file_.message : nil;
        switch (file_.state) {
            case ModelStoreIdle: return BawanModelNeedsSetupStatus;
            case ModelStoreDownloading: return message ?: @"Downloading the model…";
            case ModelStorePaused: return message ?: @"Model download paused.";
            case ModelStoreChecking:
            case ModelStoreVerifying: return message ?: BawanModelCheckingStatus;
            case ModelStoreFailed: return message ?: BawanModelFailedStatus;
            case ModelStoreReady: break;
        }
        switch (engine_) {
            case BawanEngineState::Loading: return BawanModelLoadingStatus;
            case BawanEngineState::Failed: return engineMessage_.length ? engineMessage_ : BawanModelFailedStatus;
            case BawanEngineState::Idle: return BawanModelReadyStatus;
        }
    }

private:
    void setEngine(BawanEngineState engine, NSString *message) {
        if (!hasVerifiedFile()) return;
        engine_ = engine;
        engineMessage_ = [message copy];
    }

    ModelStoreSnapshot file_;
    BawanEngineState engine_ = BawanEngineState::Idle;
    NSString *engineMessage_ = nil;
};
