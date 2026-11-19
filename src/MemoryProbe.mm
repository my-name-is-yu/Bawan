#import "MemoryProbe.h"

@implementation MemoryProbe {
    NSString *_directory;
    __weak id<MemoryProbeHost> _host;
    NSTimer *_timer;
}

+ (instancetype)probeWithEnvironment:(NSDictionary *)environment host:(id<MemoryProbeHost>)host {
    NSString *directory = environment[@"BAWAN_MEMORY_PROBE"];
    if (!directory.length) return nil;
    MemoryProbe *probe = [[self alloc] init];
    probe->_directory = [directory copy];
    probe->_host = host;
    return probe;
}

- (void)start {
    [_timer invalidate];
    __weak MemoryProbe *weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *) {
        [weakSelf tick];
    }];
}

- (void)dealloc {
    [_timer invalidate];
}

- (void)write:(NSString *)value name:(NSString *)name {
    [value writeToFile:[_directory stringByAppendingPathComponent:name]
           atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)tick {
    NSString *path = [_directory stringByAppendingPathComponent:@"command"];
    NSString *command = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!command) return;
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    id<MemoryProbeHost> host = _host;
    if ([command isEqualToString:@"translation"]) [host memoryProbeShowTranslationPanel];
    else if ([command isEqualToString:@"settings"]) [host openSettings:nil];
    else if ([command isEqualToString:@"setup"]) [host showOnboarding];
    else if ([command isEqualToString:@"close"]) [host memoryProbeClosePanel];
    else if ([command isEqualToString:@"prepare"]) [host prepareModel];
    else if ([command isEqualToString:@"model"]) {
        [self write:[host hasVerifiedModelFile] ? @"ready" :
            ([host modelFailed] ? @"error" : @"waiting") name:@"reply"];
        return;
    } else if ([command isEqualToString:@"translate"]) {
        [host translateText:@"Hello. How are you?" direction:bawan::Direction::EnglishToJapanese];
    } else if (![command isEqualToString:@"ping"]) {
        [self write:@"error" name:@"reply"];
        return;
    }
    [self write:@"ok" name:@"reply"];
}

- (void)recordEngineEvent:(bawan::EngineEvent::Kind)kind {
    using Kind = bawan::EngineEvent::Kind;
    if (kind == Kind::Complete) [self write:@"complete" name:@"engine"];
    else if (kind == Kind::Idle) [self write:@"idle" name:@"engine"];
    else if (kind == Kind::Error || kind == Kind::Cancelled)
        [self write:@"error" name:@"engine"];
}

@end
