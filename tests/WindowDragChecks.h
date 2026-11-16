#pragma once

#import <AppKit/AppKit.h>

#include <stdexcept>

static void CheckBackgroundDragPoint(NSWindow *window, NSView *region, NSPoint point,
                                     BOOL expected, NSView *expectedHit) {
    NSView *root = window.contentView;
    NSView *hit = [root hitTest:[region convertPoint:point toView:root.superview]];
    NSView *blocker = nil;
    BOOL reachesRoot = NO;
    for (NSView *view = hit; view; view = view.superview) {
        if (!view.mouseDownCanMoveWindow && !blocker) blocker = view;
        if (view == root) { reachesRoot = YES; break; }
    }
    BOOL eligible = window.movable && window.movableByWindowBackground && reachesRoot && !blocker;
    if (eligible != expected || !hit ||
        (expectedHit && hit != expectedHit && ![hit isDescendantOf:expectedHit])) {
        NSString *message = [NSString stringWithFormat:
            @"Background-drag eligibility mismatch: region=%@ point=%@ content=%@ expected=%@ hit=%@ blocker=%@",
            region.identifier, NSStringFromPoint(point), NSStringFromSize(root.bounds.size),
            @(expected), hit, blocker];
        throw std::runtime_error(message.UTF8String);
    }
}

static void CheckBackgroundDragCenter(NSWindow *window, NSView *view, BOOL expected) {
    CheckBackgroundDragPoint(window, view, NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds)), expected, view);
}

static void CheckBackgroundDragGrid(NSWindow *window, NSView *region, NSArray<NSView *> *controls) {
    NSUInteger blankPoints = 0;
    for (CGFloat y = 8; y < NSMaxY(region.bounds) - 8; y += 16) {
        for (CGFloat x = 8; x < NSMaxX(region.bounds) - 8; x += 16) {
            NSPoint point = NSMakePoint(x, y);
            NSView *control = nil;
            for (NSView *candidate in controls) {
                if (NSPointInRect([region convertPoint:point toView:candidate], candidate.bounds)) {
                    control = candidate;
                    break;
                }
            }
            CheckBackgroundDragPoint(window, region, point, control == nil, control);
            if (!control) ++blankPoints;
        }
    }
    if (!blankPoints) throw std::runtime_error("The frame drag grid must sample blank areas");
}
