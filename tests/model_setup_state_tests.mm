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
            state.phase() == BawanModelSetupNeedsDownload && state.progress() == 0 &&
            [state.message() isEqualToString:BawanModelNeedsSetupStatus],
            "A new state needs setup before entering the translator or finishing onboarding");

        state.engineLoading();
        Expect(state.engine() == BawanEngineState::Idle, "Engine events must not apply before the file is present");

        state.fileChanged({ModelStoreChecking});
        Expect(state.phase() == BawanModelSetupPreparing && state.canFinishSetup() && !state.canEnterTranslator() &&
            state.progress() == 0 && [state.message() isEqualToString:BawanModelCheckingStatus],
            "During file preparation only the explicit footer action may finish onboarding");

        state.fileChanged({ModelStoreDownloading, 0.25, @"Downloading the model… 25%"});
        Expect(state.phase() == BawanModelSetupDownloading && state.canFinishSetup() && !state.canEnterTranslator() &&
            state.progress() == 0.25 && [state.message() isEqualToString:@"Downloading the model… 25%"],
            "Downloading keeps ModelStore's progress and message without claiming a verified file");

        state.fileChanged({ModelStorePaused, 0.25, @"Download paused · 25%", nil, true});
        Expect(state.phase() == BawanModelSetupPaused && !state.failed() && state.canFinishSetup() &&
            !state.canEnterTranslator() && state.progress() == 0.25,
            "Pausing retains progress and lets the user finish optional shortcut setup");

        state.fileChanged({ModelStoreFailed, 0.75, @"Connection lost. Resume the download.", nil, true});
        Expect(state.failed() && state.phase() == BawanModelSetupResumableFailure && state.progress() == 0.75 &&
            !state.canEnterTranslator() && !state.canFinishSetup() && state.url() == nil,
            "A failed transfer with retained bytes offers resume while blocking model use");

        state.fileChanged({ModelStoreVerifying, 1, @"Download complete. Verifying SHA256…"});
        Expect(state.phase() == BawanModelSetupPreparing && !state.hasVerifiedFile() && !state.canEnterTranslator() &&
            [state.message() containsString:@"SHA256"],
            "A finished transfer remains unavailable while full SHA256 verification runs");

        state.fileChanged({ModelStoreReady, 1, nil, url});
        Expect(state.hasVerifiedFile() && state.canEnterTranslator() && [state.url() isEqual:url] &&
            state.phase() == BawanModelSetupReady && state.progress() == 1 &&
            [state.message() isEqualToString:BawanModelReadyStatus],
            "A verified file is ready");

        state.engineLoading();
        Expect(state.phase() == BawanModelSetupPreparing && state.canEnterTranslator() && state.canFinishSetup() &&
            !state.progress().has_value() && [state.message() isEqualToString:BawanModelLoadingStatus],
            "Engine loading keeps both onboarding exits available while showing indeterminate preparation");
        state.stopLoading();
        Expect(state.phase() == BawanModelSetupReady && state.progress() == 1,
            "Cancelling stops a load and restores completed file progress");

        state.engineLoading();
        state.engineFailed(@"The engine could not load the model.");
        Expect(state.failed() && !state.canEnterTranslator() && state.hasVerifiedFile() && !state.canFinishSetup() &&
            state.phase() == BawanModelSetupFailed && state.progress() == 1 &&
            [state.message() isEqualToString:@"The engine could not load the model."],
            "An engine failure keeps the verified file but blocks both onboarding exits until Retry");
        state.stopLoading();
        Expect(state.failed(), "Cancelling must keep a reported engine failure");

        state.fileChanged({ModelStoreChecking});
        Expect(!state.failed() && !state.hasVerifiedFile() && state.url() == nil &&
            state.engine() == BawanEngineState::Idle && state.progress() == 0,
            "A new preparation clears the file, engine and progress together");

        state.fileChanged({ModelStoreFailed, 0, @"Model download failed."});
        Expect(state.failed() && !state.setupNotStarted() && !state.canFinishSetup() &&
            state.phase() == BawanModelSetupFailed && state.progress() == 0 &&
            [state.message() isEqualToString:@"Model download failed."],
            "A file failure has no URL and needs Retry");

        BawanModelState silent;
        silent.fileChanged({ModelStoreDownloading});
        Expect(silent.message().length > 0, "Downloading without a message must still have status text");
        silent.fileChanged({ModelStoreFailed});
        Expect(silent.message().length > 0, "A failure without a message must still have status text");
    }
    if (failures) return EXIT_FAILURE;
    std::cout << "PASS: model setup state\n";
    return EXIT_SUCCESS;
}
