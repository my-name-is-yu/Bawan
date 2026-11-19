#import <Foundation/Foundation.h>

// What the setup pages show for the model, derived from BawanModelState.
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

// Tracks a verified model file separately from the engine that loads it.
// The URL is retained after verification until setup is restarted or fails;
// an engine failure keeps the verified file available for another load attempt.
class BawanModelState {
public:
    enum class File { Missing, Preparing, Downloading, Paused, Failed, ResumableFailure, Present };
    enum class Engine { Idle, Loading, Failed };

    // ModelStore rejects callbacks from earlier preparations using its generation.
    // This state also ignores progress outside preparation so it cannot overwrite
    // the status of a verified file or a reported failure.
    void beginPreparing() { reset(File::Preparing, nil, 0, BawanModelCheckingStatus); }
    void fileDownloading() { if (filePreparationActive()) file_ = File::Downloading; }
    void filePaused() { if (file_ == File::Downloading) file_ = File::Paused; }
    void fileVerifying() { if (file_ == File::Downloading) file_ = File::Preparing; }
    void fileProgress(double progress, NSString *message) {
        if (!filePreparationActive()) return;
        progress_ = progress;
        message_ = [message copy];
    }
    void fileReady(NSURL *url) { reset(File::Present, url, 1, nil); }
    void fileFailed(NSString *message, bool resumable = false) {
        const double savedProgress = progress_;
        reset(resumable ? File::ResumableFailure : File::Failed, nil, resumable ? savedProgress : 0, message);
    }

    // Engine transitions. They are ignored unless the file is present.
    void engineLoading() { setEngine(Engine::Loading, nil); }
    void engineIdle() { setEngine(Engine::Idle, nil); }
    void engineFailed(NSString *message) { setEngine(Engine::Failed, message); }
    // Cancelling a request stops a load in progress but keeps a reported failure.
    void stopLoading() { if (engine_ == Engine::Loading) engineIdle(); }

    File file() const { return file_; }
    Engine engine() const { return engine_; }
    NSURL *url() const { return url_; }
    bool hasVerifiedFile() const { return file_ == File::Present; }
    // No preparation has started in this process; a saved file may still exist.
    bool setupNotStarted() const { return file_ == File::Missing; }
    bool failed() const { return file_ == File::Failed || file_ == File::ResumableFailure || engine_ == Engine::Failed; }
    // Escape/Open Translator can leave setup once the file is verified. A load
    // may still be running, but a reported engine failure needs attention first.
    bool canEnterTranslator() const { return hasVerifiedFile() && engine_ != Engine::Failed; }
    // The explicit setup footer action may continue while preparation is running.
    bool canFinishSetup() const { return !setupNotStarted() && !failed(); }

    BawanModelSetupPhase phase() const {
        if (setupNotStarted()) return BawanModelSetupNeedsDownload;
        if (file_ == File::ResumableFailure) return BawanModelSetupResumableFailure;
        if (failed()) return BawanModelSetupFailed;
        if (file_ == File::Downloading) return BawanModelSetupDownloading;
        if (file_ == File::Paused) return BawanModelSetupPaused;
        if (file_ == File::Preparing || engine_ == Engine::Loading) return BawanModelSetupPreparing;
        return BawanModelSetupReady;
    }

    // A fraction in [0, 1] during transfer/checking, retained while paused or resumable.
    // Negative while an engine load has no measurable progress.
    double progress() const {
        if (file_ == File::Present) return engine_ == Engine::Loading ? -1 : 1;
        return progress_;
    }

    NSString *message() const {
        switch (file_) {
            case File::Missing: return BawanModelNeedsSetupStatus;
            case File::Downloading: return message_.length ? message_ : @"Downloading the model…";
            case File::Paused: return message_.length ? message_ : @"Model download paused.";
            case File::Preparing: return message_.length ? message_ : BawanModelCheckingStatus;
            case File::ResumableFailure:
            case File::Failed: return message_.length ? message_ : BawanModelFailedStatus;
            case File::Present: break;
        }
        switch (engine_) {
            case Engine::Loading: return BawanModelLoadingStatus;
            case Engine::Failed: return message_.length ? message_ : BawanModelFailedStatus;
            case Engine::Idle: break;
        }
        return BawanModelReadyStatus;
    }

private:
    bool filePreparationActive() const {
        return file_ == File::Preparing || file_ == File::Downloading || file_ == File::Paused;
    }
    void reset(File file, NSURL *url, double progress, NSString *message) {
        file_ = file;
        url_ = url;
        engine_ = Engine::Idle;
        progress_ = progress;
        message_ = [message copy];
    }
    void setEngine(Engine engine, NSString *message) {
        if (file_ != File::Present) return;
        engine_ = engine;
        message_ = [message copy];
    }

    File file_ = File::Missing;
    Engine engine_ = Engine::Idle;
    NSURL *url_ = nil;
    double progress_ = 0;
    NSString *message_ = nil;
};
