#import "SelectionResult.h"

@implementation SelectionResult
- (instancetype)initWithKind:(SelectionResultKind)kind text:(NSString *)text {
    self = [super init];
    if (!self) return nil;
    _kind = kind;
    _text = [text copy];
    return self;
}
@end
