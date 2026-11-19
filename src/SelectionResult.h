#import <Foundation/Foundation.h>

#include <type_traits>
#include <variant>

struct SelectedText {
    NSString *__strong text;
    explicit SelectedText(NSString *value) : text([value copy]) {}
};

struct SelectionTrial {
    NSString *__strong text;
    explicit SelectionTrial(NSString *value) : text([value copy]) {}
};

struct SelectionProblem {
    NSString *__strong message;
    explicit SelectionProblem(NSString *value) : message([value copy]) {}
};

using SelectionReadResult = std::variant<SelectedText, SelectionProblem>;
using SelectionEvent = std::variant<SelectedText, SelectionTrial, SelectionProblem>;
