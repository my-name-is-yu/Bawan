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
        Expect(state.needsDownload() && !state.available() && !state.failed() && state.url() == nil &&
            state.phase() == BawanModelSetupNeedsDownload && [state.message() isEqualToString:BawanModelNeedsSetupStatus],
            "A new state needs the model download");

        state.engineLoading();
        Expect(state.engine() == BawanModelState::Engine::Idle,
            "Engine events must not apply before the file is present");

        state.fileProgress(0.5, @"Stray progress");
        Expect(state.needsDownload() && state.progress() == 0,
            "Progress must not start a preparation on its own");

        state.beginPreparing();
        Expect(state.phase() == BawanModelSetupPreparing && state.settingUpOrReady() &&
            [state.message() isEqualToString:BawanModelCheckingStatus], "Setup starts by checking the model");

        state.fileProgress(0.25, @"Downloading the model… 25%");
        Expect(state.progress() == 0.25 && [state.message() isEqualToString:@"Downloading the model… 25%"],
            "Progress keeps ModelStore's own message");

        state.fileReady(url);
        Expect(state.available() && state.ready() && [state.url() isEqual:url] &&
            state.phase() == BawanModelSetupReady && [state.message() isEqualToString:BawanModelReadyStatus],
            "A verified file is ready");
        state.fileProgress(0.9, @"Late progress");
        Expect(state.available() && [state.url() isEqual:url] && [state.message() isEqualToString:BawanModelReadyStatus],
            "A late progress report must not undo a ready model");

        state.engineLoading();
        Expect(state.phase() == BawanModelSetupPreparing && state.ready() && state.progress() < 0 &&
            [state.message() isEqualToString:BawanModelLoadingStatus],
            "Loading is shown as preparation, not as Ready, while translation can still queue");
        state.stopLoading();
        Expect(state.phase() == BawanModelSetupReady, "Cancelling stops a load in progress");

        state.engineFailed(@"The engine could not load the model.");
        Expect(state.failed() && !state.ready() && state.available() && !state.settingUpOrReady() &&
            state.phase() == BawanModelSetupFailed &&
            [state.message() isEqualToString:@"The engine could not load the model."],
            "An engine failure keeps the file but needs Retry");
        state.stopLoading();
        Expect(state.failed(), "Cancelling must keep a reported engine failure");

        state.beginPreparing();
        Expect(!state.failed() && !state.available() && state.url() == nil &&
            state.engine() == BawanModelState::Engine::Idle, "Retry clears the file and engine state together");

        state.fileFailed(@"Model download failed.");
        Expect(state.failed() && !state.available() && state.url() == nil && !state.needsDownload() &&
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
