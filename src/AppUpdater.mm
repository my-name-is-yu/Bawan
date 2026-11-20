#import "AppUpdater.h"

#if BAWAN_ENABLE_UPDATES
#import <Sparkle/Sparkle.h>
#import "ApplicationRunLoop.h"

@interface AppUpdater () <SPUUpdaterDelegate> {
    SPUStandardUpdaterController *_controller;
    void (^_pendingRelaunch)(void);
    BOOL _observing;
    BOOL _installingUpdate;
}
- (void)setInstallingUpdate:(BOOL)installingUpdate;
@end
#endif

@implementation AppUpdater

- (BOOL)available {
#if BAWAN_ENABLE_UPDATES
    return _controller != nil;
#else
    return NO;
#endif
}

- (BOOL)installingUpdate {
#if BAWAN_ENABLE_UPDATES
    return _installingUpdate;
#else
    return NO;
#endif
}

- (BOOL)relaunchPostponed {
#if BAWAN_ENABLE_UPDATES
    return _pendingRelaunch != nil;
#else
    return NO;
#endif
}

- (void)start {
#if BAWAN_ENABLE_UPDATES
    if (_controller) return;
    _controller = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:NO
        updaterDelegate:self userDriverDelegate:nil];
    for (NSString *key in @[@"canCheckForUpdates", @"automaticallyChecksForUpdates"]) {
        [_controller.updater addObserver:self forKeyPath:key options:0 context:nullptr];
    }
    _observing = YES;
    [_controller startUpdater];
    if (self.onStateChanged) self.onStateChanged();
#endif
}

- (BOOL)canCheckForUpdates {
#if BAWAN_ENABLE_UPDATES
    return !_translationBusy && !_installingUpdate && _controller.updater.canCheckForUpdates;
#else
    return NO;
#endif
}

- (BOOL)automaticallyChecksForUpdates {
#if BAWAN_ENABLE_UPDATES
    return _controller.updater.automaticallyChecksForUpdates;
#else
    return NO;
#endif
}

- (void)setAutomaticallyChecksForUpdates:(BOOL)enabled {
#if BAWAN_ENABLE_UPDATES
    _controller.updater.automaticallyChecksForUpdates = enabled;
#endif
}

- (void)checkForUpdates:(id)sender {
#if BAWAN_ENABLE_UPDATES
    if (self.canCheckForUpdates) [_controller checkForUpdates:sender];
#endif
}

- (void)setTranslationBusy:(BOOL)busy {
    _translationBusy = busy;
    if (self.onStateChanged) self.onStateChanged();
}

#if BAWAN_ENABLE_UPDATES
- (void)setInstallingUpdate:(BOOL)installingUpdate {
    if (_installingUpdate == installingUpdate) return;
    _installingUpdate = installingUpdate;
    if (self.onStateChanged) self.onStateChanged();
}
#endif

- (void)resumePostponedRelaunch {
#if BAWAN_ENABLE_UPDATES
    if (!_pendingRelaunch) return;
    __weak AppUpdater *weakSelf = self;
    PerformInApplicationRunLoop(^{
        AppUpdater *owner = weakSelf;
        if (!owner || owner->_translationActive || !owner->_pendingRelaunch) return;
        void (^relaunch)(void) = owner->_pendingRelaunch;
        owner->_pendingRelaunch = nil;
        [owner setInstallingUpdate:YES];
        relaunch();
    });
#endif
}

#if BAWAN_ENABLE_UPDATES
- (BOOL)updater:(SPUUpdater *)updater mayPerformUpdateCheck:(SPUUpdateCheck)check error:(NSError **)error {
    if (!_translationBusy && !_installingUpdate) return YES;
    NSString *message = _installingUpdate ?
        @"An update is already installing." : @"Finish or cancel the translation before checking for updates.";
    if (error) *error = [NSError errorWithDomain:@"local.bawan.Updates" code:1 userInfo:@{
        NSLocalizedDescriptionKey: message}];
    return NO;
}

- (void)updater:(SPUUpdater *)updater willInstallUpdate:(SUAppcastItem *)item {
    [self setInstallingUpdate:YES];
}

- (BOOL)updater:(SPUUpdater *)updater shouldPostponeRelaunchForUpdate:(SUAppcastItem *)item
    untilInvokingBlock:(void (^)(void))installHandler {
    if (_translationActive) {
        _pendingRelaunch = [installHandler copy];
        return YES;
    }
    [self setInstallingUpdate:YES];
    return NO;
}

- (void)updater:(SPUUpdater *)updater didAbortWithError:(NSError *)error {
    const BOOL postponed = self.relaunchPostponed;
    _pendingRelaunch = nil;
    if (_installingUpdate) [self setInstallingUpdate:NO];
    else if (postponed && self.onStateChanged) self.onStateChanged();
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
    change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context {
    if (object == _controller.updater) {
        if (self.onStateChanged) self.onStateChanged();
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)dealloc {
    if (_observing) {
        for (NSString *key in @[@"canCheckForUpdates", @"automaticallyChecksForUpdates"]) {
            [_controller.updater removeObserver:self forKeyPath:key];
        }
    }
}
#endif
@end
