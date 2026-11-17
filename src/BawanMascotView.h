#pragma once
#import <AppKit/AppKit.h>

// The animated Bawan dog. By default it sits in the gold masthead medallion;
// the plain variant draws the dog alone at a larger size with the same motion.
@interface BawanMascotView : NSImageView
- (instancetype)initPlainWithPointSize:(CGFloat)pointSize;
- (void)resetHoverAnimation;
@end
