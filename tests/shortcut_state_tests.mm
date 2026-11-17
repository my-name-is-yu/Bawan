#import "ShortcutMonitor.h"

#include <algorithm>
#include <cstdlib>
#include <iostream>

@interface StateTestMonitor : ShortcutMonitor
@property(nonatomic) BOOL inputPermission;
@property(nonatomic) BOOL accessibilityPermission;
@end

@implementation StateTestMonitor
- (BOOL)hasInputMonitoringPermission { return _inputPermission; }
- (BOOL)hasAccessibilityPermission { return _accessibilityPermission; }
- (BOOL)installTapActive:(BOOL)active { (void)active; return NO; }
- (void)removeTapActive:(BOOL)active { (void)active; }
@end

static void require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        constexpr auto selection = bawan::ShortcutAction::TranslateSelection;
        constexpr auto panel = bawan::ShortcutAction::OpenPanel;
        NSString *suite = [@"local.bawan.ShortcutStateTests." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        ShortcutPreferences *preferences = [[ShortcutPreferences alloc] initWithDefaults:defaults];
        StateTestMonitor *monitor = [[StateTestMonitor alloc] initWithPreferences:preferences];
        __weak StateTestMonitor *weakMonitor = monitor;
        __block ShortcutAvailability expectedSelection = ShortcutAvailabilityNeedsInputMonitoring;
        __block ShortcutAvailability expectedPanel = ShortcutAvailabilityNeedsAccessibility;
        __block unsigned callbacks = 0, depth = 0, maximumDepth = 0;
        __block unsigned earlierReads = 0, laterReads = 0;
        __block BOOL rewritePanel = NO, reenterCallback = NO;
        void (^checkState)(void) = ^{
            require([weakMonitor availabilityForAction:selection] == expectedSelection,
                    "selection availability reflects the latest binding and permission");
            require([weakMonitor availabilityForAction:panel] == expectedPanel,
                    "panel availability reflects the latest binding and permission");
        };
        monitor.onStateChanged = ^{
            ++callbacks;
            maximumDepth = std::max(maximumDepth, ++depth);
            checkState();
            [weakMonitor refresh];
            if (reenterCallback) {
                reenterCallback = NO;
                const unsigned before = callbacks;
                auto binding = [preferences bindingForAction:panel];
                binding.enabled = true;
                expectedPanel = ShortcutAvailabilityFailed;
                require([preferences setBinding:binding forAction:panel error:nil],
                        "a state callback can change another binding");
                checkState();
                require(callbacks == before,
                        "a callback applies reentrant changes immediately without nested publication");
            }
            --depth;
        };

        // Raw observers deliberately refresh on both sides of the monitor's
        // subscription. Neither subscriber delivery order may expose old state.
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        id earlier = [center addObserverForName:BawanShortcutsDidChangeNotification object:preferences
            queue:nil usingBlock:^(NSNotification *) {
            ++earlierReads;
            if (rewritePanel) {
                rewritePanel = NO;
                auto binding = [preferences bindingForAction:panel];
                binding.enabled = false;
                expectedPanel = ShortcutAvailabilityOff;
                require([preferences setBinding:binding forAction:panel error:nil],
                        "a raw preference observer can reenter the setter");
            }
            [weakMonitor refresh];
            checkState();
        }];
        [monitor start];
        require(callbacks == 1, "starting publishes one complete initial state");
        id later = [center addObserverForName:BawanShortcutsDidChangeNotification object:preferences
            queue:nil usingBlock:^(NSNotification *) {
            ++laterReads;
            [weakMonitor refresh];
            checkState();
        }];

        auto binding = [preferences bindingForAction:panel];
        binding.keyCode = 5;
        binding.pressCount = 1;
        require([preferences setBinding:binding forAction:panel error:nil], "change a custom key and press count");
        require(callbacks == 2 && earlierReads == 1 && laterReads == 1,
                "a binding-only change publishes once regardless of raw observer refreshes");
        require([preferences bindingForAction:panel] == binding, "the published custom binding is saved");
        require([preferences setBinding:binding forAction:panel error:nil], "the same binding is a successful no-op");
        require(callbacks == 2 && earlierReads == 1 && laterReads == 1,
                "a no-op setter does not publish or send raw notifications");
        NSString *error = nil;
        auto duplicate = [preferences bindingForAction:selection];
        require(![preferences setBinding:duplicate forAction:panel error:&error] && error.length,
                "a duplicate shortcut is rejected");
        require(callbacks == 2 && [preferences bindingForAction:panel] == binding,
                "a failed setter preserves both state and publication count");

        auto selectionBinding = [preferences bindingForAction:selection];
        selectionBinding.enabled = false;
        expectedSelection = ShortcutAvailabilityOff;
        require([preferences setBinding:selectionBinding forAction:selection error:nil], "disable selection");
        require(callbacks == 3, "disabling publishes one complete state");
        monitor.accessibilityPermission = YES;
        expectedPanel = ShortcutAvailabilityFailed;
        [monitor refresh];
        require(callbacks == 4, "a permission-only change publishes once");
        [monitor refresh];
        require(callbacks == 4, "unchanged availability and recursive refresh do not republish");

        [monitor updateConfiguration:^{
            auto enabled = [preferences bindingForAction:selection];
            enabled.enabled = true;
            expectedSelection = ShortcutAvailabilityNeedsInputMonitoring;
            require([preferences setBinding:enabled forAction:selection error:nil], "reenable selection");
            [monitor updateConfiguration:^{
                monitor.inputPermission = YES;
                expectedSelection = ShortcutAvailabilityFailed;
                [monitor refresh];
            }];
            require(callbacks == 4, "nested configuration updates defer publication");
            checkState();
        }];
        require(callbacks == 5, "enabling and refreshing permissions publish one final state");
        [monitor updateConfiguration:^{}];
        require(callbacks == 6, "a no-op UI transaction requests one state resynchronization");
        [monitor updateConfiguration:^{
            require(![preferences setBinding:duplicate forAction:panel error:nil], "reject an invalid UI update");
        }];
        require(callbacks == 7, "a rejected UI transaction requests one state resynchronization");

        const unsigned readsBefore = earlierReads;
        rewritePanel = YES;
        [monitor updateConfiguration:^{
            auto custom = [preferences bindingForAction:selection];
            custom.keyCode = 4;
            custom.modifiers = bawan::Option;
            require([preferences setBinding:custom forAction:selection error:nil], "change selection during a transaction");
        }];
        require(callbacks == 8 && earlierReads == readsBefore + 2 && laterReads == earlierReads,
                "reentrant raw notifications publish only the final transaction state");
        require(![preferences bindingForAction:panel].enabled &&
                [preferences bindingForAction:selection].keyCode == 4,
                "the transaction exposes both final bindings");

        reenterCallback = YES;
        auto custom = [preferences bindingForAction:selection];
        custom.pressCount = 1;
        require([preferences setBinding:custom forAction:selection error:nil], "trigger a reentrant state callback");
        require(callbacks == 10 && maximumDepth == 1 && depth == 0,
                "reentrant changes publish a second complete state after the current callback returns");
        require([preferences bindingForAction:panel].enabled, "the callback's update is retained");
        checkState();

        [center removeObserver:earlier];
        [center removeObserver:later];
        monitor.onStateChanged = nil;
        [monitor stop];
        [defaults removePersistentDomainForName:suite];
    }
    std::cout << "Shortcut state tests passed\n";
}
