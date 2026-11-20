#pragma once

#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>

inline void PerformInApplicationRunLoop(dispatch_block_t block) {
    CFRunLoopRef runLoop = CFRunLoopGetMain();
    NSArray<NSString *> *modes = @[NSDefaultRunLoopMode, NSModalPanelRunLoopMode];
    CFRunLoopPerformBlock(runLoop, (__bridge CFArrayRef)modes, block);
    CFRunLoopWakeUp(runLoop);
}
