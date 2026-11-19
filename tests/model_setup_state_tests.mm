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
        Expect(state.engine() == BawanModelState::Engine::Idle,
            "Engine events must not apply before the file is present");

        state.fileProgress(0.5, @"Stray progress");
        Expect(state.setupNotStarted() && state.progress() == 0,
            "Progress must not start a preparation on its own");

        state.beginPreparing();
        Expect(state.phase() == BawanModelSetupPreparing && state.canFinishSetup() && !state.canEnterTranslator() &&
            state.progress() == 0 && [state.message() isEqualToString:BawanModelCheckingStatus],
            "During file preparation only the explicit footer action may finish onboarding");

        state.fileProgress(0.25, @"Downloading the model… 25%");
        Expect(state.progress() == 0.25 && [state.message() isEqualToString:@"Downloading the model… 25%"],
            "Progress keeps ModelStore's own message");

        state.fileReady(url);
        Expect(state.hasVerifiedFile() && state.canEnterTranslator() && [state.url() isEqual:url] &&
            state.phase() == BawanModelSetupReady && state.progress() == 1 &&
            [state.message() isEqualToString:BawanModelReadyStatus],
            "A verified file is ready");
        state.fileProgress(0.9, @"Late progress");
        Expect(state.hasVerifiedFile() && [state.url() isEqual:url] && state.progress() == 1 &&
            [state.message() isEqualToString:BawanModelReadyStatus],
            "A late progress report must not undo a ready model");

        state.engineLoading();
        Expect(state.phase() == BawanModelSetupPreparing && state.hasVerifiedFile() && state.canEnterTranslator() &&
            state.canFinishSetup() && !state.progress().has_value() &&
            [state.message() isEqualToString:BawanModelLoadingStatus],
            "Engine loading keeps both onboarding exits available while showing preparation");
        state.fileProgress(0.7, @"Late download progress");
        Expect(!state.progress().has_value(), "Late file progress must not replace indeterminate engine loading");
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

        state.beginPreparing();
        Expect(!state.failed() && !state.hasVerifiedFile() && state.url() == nil &&
            state.engine() == BawanModelState::Engine::Idle && state.progress() == 0,
            "Retry clears the file, engine and progress together");

        state.fileFailed(@"Model download failed.");
        Expect(state.failed() && !state.hasVerifiedFile() && state.url() == nil && !state.setupNotStarted() &&
            !state.canEnterTranslator() && !state.canFinishSetup() &&
            state.phase() == BawanModelSetupFailed && state.progress() == 0 &&
            [state.message() isEqualToString:@"Model download failed."],
            "A file failure has no URL and needs Retry");

        state.beginPreparing();
        state.fileReady(url);
        state.engineLoading();
        state.engineIdle();
        Expect(state.phase() == BawanModelSetupReady && state.progress() == 1,
            "Completing an engine load restores completed file progress");

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
