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
        Expect(state.phase() == BawanModelSetupNeedsDownload, "Engine events must not apply before the file is present");

        state.fileChanged(ModelVerifying{ModelFileKind::Saved});
        Expect(state.phase() == BawanModelSetupPreparing && state.canFinishSetup() && !state.canEnterTranslator() &&
            state.progress() == 0 && [state.message() isEqualToString:@"Checking the saved model…"],
            "During file preparation only the explicit footer action may finish onboarding");

        state.fileChanged(ModelDownloading{0, ModelDownloadStage::Starting});
        Expect([state.message() isEqualToString:@"Downloading the model…"], "A starting download has no percentage");
        state.fileChanged(ModelDownloading{0.25, ModelDownloadStage::Resuming});
        Expect([state.message() isEqualToString:@"Resuming the model download…"], "A resumed download says so");
        state.fileChanged(ModelDownloading{0, ModelDownloadStage::Restarted});
        Expect([state.message() containsString:@"restarted"], "A server restart is explained");
        state.fileChanged(ModelDownloading{0.25, ModelDownloadStage::Receiving});
        Expect(state.phase() == BawanModelSetupDownloading && state.canFinishSetup() && !state.canEnterTranslator() &&
            state.progress() == 0.25 && [state.message() isEqualToString:@"Downloading the model… 25%"],
            "Receiving shows the store's progress without claiming a verified file");

        state.fileChanged(ModelPaused{0.25, true});
        Expect(state.phase() == BawanModelSetupPaused && !state.failed() && state.canFinishSetup() &&
            !state.canEnterTranslator() && state.progress() == 0.25 &&
            [state.message() isEqualToString:@"Model download paused. Resume to continue."],
            "Pausing retains progress and lets the user finish optional shortcut setup");
        state.fileChanged(ModelPaused{0.25, false});
        Expect([state.message() containsString:@"restart the download"], "A pause without a validator restarts");

        state.fileChanged(ModelFailed{ModelInterrupted{@"Connection lost."}, 0.75});
        Expect(state.failed() && state.phase() == BawanModelSetupResumableFailure && state.progress() == 0.75 &&
            !state.canEnterTranslator() && !state.canFinishSetup() && state.url() == nil &&
            [state.message() isEqualToString:@"Model download interrupted. Connection lost. Resume to continue the download."],
            "A failed transfer with retained bytes offers resume while blocking model use");

        state.fileChanged(ModelFailed{ModelHTTPFailed{503}});
        Expect(state.phase() == BawanModelSetupFailed && state.progress() == 0 &&
            [state.message() isEqualToString:@"Model download failed (HTTP 503). Please try again."],
            "A failure without retained bytes needs a fresh retry");

        state.fileChanged(ModelVerifying{ModelFileKind::Download});
        Expect(state.phase() == BawanModelSetupPreparing && !state.hasVerifiedFile() && !state.canEnterTranslator() &&
            state.progress() == 1 && [state.message() containsString:@"SHA256"],
            "A finished transfer remains unavailable while full SHA256 verification runs");

        state.fileChanged(ModelFailed{ModelCheckFailed{ModelCheckIssue::HashMismatch, ModelFileKind::Download}});
        Expect([state.message() isEqualToString:@"The model file failed SHA256 verification. The partial download was "
                                                 "discarded. Please try again to download the model."],
            "A rejected download says its partial was discarded");
        state.fileChanged(ModelFailed{ModelIssue::PathOccupied});
        Expect([state.message() containsString:@"occupied"], "Issues map to their own copy");

        state.fileChanged(ModelReady{url});
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
        state.engineFailed(nil);
        Expect([state.message() isEqualToString:BawanModelFailedStatus], "An engine failure without text has copy");

        state.fileChanged(ModelVerifying{ModelFileKind::Saved});
        Expect(!state.failed() && !state.hasVerifiedFile() && state.url() == nil && state.progress() == 0,
            "A new preparation clears the file and its engine together");
        state.fileChanged(ModelReady{url});
        Expect(state.phase() == BawanModelSetupReady, "A file verified again starts with an idle engine");
    }
    if (failures) return EXIT_FAILURE;
    std::cout << "PASS: model setup state\n";
    return EXIT_SUCCESS;
}
