#import "ModelSetupState.h"

#include <cstdlib>
#include <iostream>

static int failures = 0;

static void Expect(bool condition, const char *message) {
    if (condition) return;
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
}

int main() {
    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithPath:@"/__bawan_tests__/model.gguf"];

        BawanModelState state;
        Expect(state.setupNotStarted() && !state.hasVerifiedFile() && !state.failed() && state.url() == nil &&
            !state.canEnterTranslator() && !state.canFinishSetup() &&
            state.phase() == BawanModelSetupNeedsDownload && [state.message() isEqualToString:BawanModelNeedsSetupStatus],
            "A new state needs setup before entering the translator or finishing onboarding");

        state.engineLoading();
        Expect(state.engine() == BawanModelState::Engine::Idle,
            "Engine events must not apply before the file is present");

        state.fileProgress(0.5, @"Stray progress");
        Expect(state.setupNotStarted() && state.progress() == 0,
            "Progress must not start a preparation on its own");

        state.beginPreparing();
        Expect(state.phase() == BawanModelSetupPreparing && state.canFinishSetup() && !state.canEnterTranslator() &&
            [state.message() isEqualToString:BawanModelCheckingStatus],
            "During file preparation only the explicit footer action may finish onboarding");

        state.fileProgress(0.25, @"Downloading the model… 25%");
        Expect(state.progress() == 0.25 && [state.message() isEqualToString:@"Downloading the model… 25%"],
            "Progress keeps ModelStore's own message");

        state.fileDownloading();
        Expect(state.phase() == BawanModelSetupDownloading && state.canFinishSetup() &&
            !state.canEnterTranslator() && state.progress() == 0.25,
            "Downloading exposes its own phase without losing progress or claiming a verified file");
        state.filePaused();
        state.fileProgress(0.25, @"Download paused · 25%");
        Expect(state.phase() == BawanModelSetupPaused && !state.failed() && state.canFinishSetup() &&
            !state.canEnterTranslator() && state.progress() == 0.25 &&
            [state.message() isEqualToString:@"Download paused · 25%"],
            "Pausing retains progress and lets the user finish optional shortcut setup");
        state.fileDownloading();
        state.fileProgress(0.75, @"Downloading the model… 75%");
        Expect(state.phase() == BawanModelSetupDownloading && state.progress() == 0.75,
            "Resuming returns to download progress");
        state.fileFailed(@"Connection lost. Resume the download.", true);
        Expect(state.failed() && state.phase() == BawanModelSetupResumableFailure && state.progress() == 0.75 &&
            !state.canEnterTranslator() && !state.canFinishSetup() && state.url() == nil,
            "A failed transfer with retained bytes offers resume while blocking model use");
        state.fileProgress(1, @"Late progress");
        Expect(state.phase() == BawanModelSetupResumableFailure &&
            [state.message() isEqualToString:@"Connection lost. Resume the download."],
            "Late progress must not hide a resumable transfer failure");
        state.beginPreparing();
        state.fileDownloading();
        state.fileVerifying();
        state.fileProgress(1, @"Download complete. Verifying SHA256…");
        Expect(state.phase() == BawanModelSetupPreparing && !state.hasVerifiedFile() &&
            !state.canEnterTranslator() && [state.message() containsString:@"SHA256"],
            "A finished transfer remains unavailable while full SHA256 verification runs");

        state.fileReady(url);
        Expect(state.hasVerifiedFile() && state.canEnterTranslator() && [state.url() isEqual:url] &&
            state.phase() == BawanModelSetupReady && [state.message() isEqualToString:BawanModelReadyStatus],
            "A verified file is ready");
        state.fileProgress(0.9, @"Late progress");
        Expect(state.hasVerifiedFile() && [state.url() isEqual:url] && [state.message() isEqualToString:BawanModelReadyStatus],
            "A late progress report must not undo a ready model");

        state.engineLoading();
        Expect(state.phase() == BawanModelSetupPreparing && state.hasVerifiedFile() && state.canEnterTranslator() &&
            state.canFinishSetup() && state.progress() < 0 &&
            [state.message() isEqualToString:BawanModelLoadingStatus],
            "Engine loading keeps both onboarding exits available while showing preparation");
        state.stopLoading();
        Expect(state.phase() == BawanModelSetupReady, "Cancelling stops a load in progress");

        state.engineFailed(@"The engine could not load the model.");
        Expect(state.failed() && !state.canEnterTranslator() && state.hasVerifiedFile() && !state.canFinishSetup() &&
            state.phase() == BawanModelSetupFailed &&
            [state.message() isEqualToString:@"The engine could not load the model."],
            "An engine failure keeps the verified file but blocks both onboarding exits until Retry");
        state.stopLoading();
        Expect(state.failed(), "Cancelling must keep a reported engine failure");

        state.beginPreparing();
        Expect(!state.failed() && !state.hasVerifiedFile() && state.url() == nil &&
            state.engine() == BawanModelState::Engine::Idle, "Retry clears the file and engine state together");

        state.fileFailed(@"Model download failed.");
        Expect(state.failed() && !state.hasVerifiedFile() && state.url() == nil && !state.setupNotStarted() &&
            !state.canEnterTranslator() && !state.canFinishSetup() &&
            state.phase() == BawanModelSetupFailed && [state.message() isEqualToString:@"Model download failed."],
            "A file failure has no URL and needs Retry");

        BawanModelState silent;
        silent.beginPreparing();
        silent.fileProgress(0, nil);
        Expect(silent.message().length > 0, "Preparing without a message must still have status text");
        silent.fileFailed(nil);
        Expect(silent.message().length > 0, "A failure without a message must still have status text");
    }
    if (failures) return EXIT_FAILURE;
    std::cout << "PASS: model setup state\n";
    return EXIT_SUCCESS;
}
