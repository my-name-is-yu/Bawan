#import <Foundation/Foundation.h>

// What the setup pages show for the model, derived from BawanModelState.
typedef NS_ENUM(NSInteger, BawanModelSetupPhase) {
    BawanModelSetupNeedsDownload,
    BawanModelSetupPreparing,
    BawanModelSetupReady,
    BawanModelSetupFailed
};

static NSString *const BawanModelNeedsSetupStatus = @"Prepare the translation model to get started.";
static NSString *const BawanModelCheckingStatus = @"Checking the model…";
static NSString *const BawanModelLoadingStatus = @"Loading the model…";
static NSString *const BawanModelFailedStatus = @"The model could not be prepared. Please try again.";
static NSString *const BawanModelReadyStatus = @"Ready to translate · On-device processing";

// The model's whole lifecycle in one place: the file on disk first, then the
// engine that loads it. The URL exists exactly while the file is present, and
// engine state only applies to a present file, so the two can never disagree.
class BawanModelState {
public:
    enum class File { Missing, Preparing, Failed, Present };
    enum class Engine { Idle, Loading, Failed };

    // File transitions. Only an explicit setup or Retry starts preparing; ModelStore's
    // progress, ready and error reports then apply to that preparation alone, so a
    // late report can never undo a finished one.
    void beginPreparing() { reset(File::Preparing, nil, 0, BawanModelCheckingStatus); }
    void fileProgress(double progress, NSString *message) {
        if (file_ != File::Preparing) return;
        progress_ = progress;
        message_ = [message copy];
    }
    void fileReady(NSURL *url) { reset(File::Present, url, 1, nil); }
    void fileFailed(NSString *message) { reset(File::Failed, nil, 0, message); }

    // Engine transitions. They are ignored unless the file is present.
    void engineLoading() { setEngine(Engine::Loading, nil); }
    void engineIdle() { setEngine(Engine::Idle, nil); }
    void engineFailed(NSString *message) { setEngine(Engine::Failed, message); }
    // Cancelling a request stops a load in progress but keeps a reported failure.
    void stopLoading() { if (engine_ == Engine::Loading) engineIdle(); }

    File file() const { return file_; }
    Engine engine() const { return engine_; }
    NSURL *url() const { return url_; }
    bool available() const { return file_ == File::Present; }
    bool needsDownload() const { return file_ == File::Missing; }
    bool failed() const { return file_ == File::Failed || engine_ == Engine::Failed; }
    // Usable for translation now: present and not failed (a load may still be running).
    bool ready() const { return available() && engine_ != Engine::Failed; }
    // The user has nothing to do: the model is being prepared or is ready.
    bool settingUpOrReady() const { return !needsDownload() && !failed(); }

    BawanModelSetupPhase phase() const {
        if (needsDownload()) return BawanModelSetupNeedsDownload;
        if (failed()) return BawanModelSetupFailed;
        if (file_ == File::Preparing || engine_ == Engine::Loading) return BawanModelSetupPreparing;
        return BawanModelSetupReady;
    }

    // A fraction in [0, 1] while preparing; negative while a load has no measurable progress.
    double progress() const {
        if (file_ == File::Present) return engine_ == Engine::Loading ? -1 : 1;
        return progress_;
    }

    NSString *message() const {
        switch (file_) {
            case File::Missing: return BawanModelNeedsSetupStatus;
            case File::Preparing: return message_.length ? message_ : BawanModelCheckingStatus;
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
