#import "MemoryProbe.h"

@implementation MemoryProbe {
    NSString *_directory;
    NSDictionary<NSString *, NSString *(^)(void)> *_commands;
    NSTimer *_timer;
}

- (instancetype)initWithDirectory:(NSString *)directory commands:(NSDictionary<NSString *, NSString *(^)(void)> *)commands {
    self = [super init];
    if (self) {
        _directory = [directory copy];
        _commands = [commands copy];
    }
    return self;
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
    NSString *(^action)(void) = _commands[command];
    [self write:action ? action() : @"error" name:@"reply"];
}

- (void)recordEngineEvent:(const bawan::EngineEvent &)event {
    if (const auto *value = bawan::engine::describe(event).probeValue) [self write:@(value) name:@"engine"];
}

@end
