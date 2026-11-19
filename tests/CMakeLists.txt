cmake_minimum_required(VERSION 3.24)
project(BawanPortableTests LANGUAGES CXX)

enable_testing()
add_executable(translation_session_tests translation_session_tests.cpp ../src/TranslationSession.cpp)
target_include_directories(translation_session_tests PRIVATE ../src)
set_target_properties(translation_session_tests PROPERTIES
    CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
if(MSVC)
    target_compile_options(translation_session_tests PRIVATE /W4 /WX /utf-8)
else()
    target_compile_options(translation_session_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()
add_test(NAME translation_session COMMAND translation_session_tests)
