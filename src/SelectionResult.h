#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SelectionResultKind) {
    SelectionResultKindText,
    SelectionResultKindTrial,
    SelectionResultKindProblem
};

@interface SelectionResult : NSObject
@property(nonatomic, readonly) SelectionResultKind kind;
@property(nonatomic, copy, readonly) NSString *text;
- (instancetype)initWithKind:(SelectionResultKind)kind text:(NSString *)text NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
