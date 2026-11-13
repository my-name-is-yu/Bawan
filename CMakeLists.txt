cmake_minimum_required(VERSION 3.24)

if(CMAKE_HOST_APPLE OR CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS version")
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Target architecture")
endif()
project(Lore VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()
option(LORE_BUILD_APP "Build the macOS menu bar application" ${APPLE})
option(LORE_BUILD_TESTS "Build Lore's behavior tests and macOS panel smoke test" OFF)
option(LORE_BUILD_SMOKE "Build the real-model inference smoke test" OFF)

# Enable native languages before configuring Metal's .m sources in llama.cpp.
# Enabling OBJCXX after add_subdirectory leaves its compile rule unavailable
# in dependency directories when CMake generates the build system.
if(APPLE)
    enable_language(OBJC OBJCXX)
    set(CMAKE_OBJCXX_STANDARD 17)
    set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
endif()

if(LORE_BUILD_APP AND NOT APPLE)
    message(FATAL_ERROR "Lore.app requires macOS 14+, Apple's SDK and an Apple Silicon Mac. Use -DLORE_BUILD_APP=OFF for portable engine checks.")
endif()

# Build only the inference library. No server, web UI, Python or Rust tools.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_CCACHE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_RPC OFF CACHE BOOL "" FORCE)
set(GGML_METAL ${APPLE} CACHE BOOL "" FORCE)
set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "" FORCE)
set(GGML_ACCELERATE ${APPLE} CACHE BOOL "" FORCE)
set(GGML_BLAS ${APPLE} CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_UI OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(LLAMA_LLGUIDANCE OFF CACHE BOOL "" FORCE)
set(LLAMA_SUBPROCESS OFF CACHE BOOL "" FORCE)
include(FetchContent)
FetchContent_Declare(llama
    URL https://codeload.github.com/ggml-org/llama.cpp/tar.gz/refs/tags/b12307
    URL_HASH SHA256=d786a73bc7262f75832e159d94455e0c8d3501bafa59cc2728573a1596dca056
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(llama)

find_package(Threads REQUIRED)
add_library(lore_engine STATIC src/TranslationEngine.cpp)
target_include_directories(lore_engine PUBLIC src)
target_link_libraries(lore_engine PUBLIC llama Threads::Threads)
target_compile_options(lore_engine PRIVATE -Wall -Wextra -Wpedantic)

add_library(lore_gesture STATIC src/CopyGesture.cpp src/ShortcutBinding.cpp)
target_include_directories(lore_gesture PUBLIC src)
target_compile_options(lore_gesture PRIVATE -Wall -Wextra -Wpedantic)

set(LORE_UI_RESOURCES resources/LoreMascot.png resources/PaperGrain.png)

if(LORE_BUILD_APP)
    add_executable(Lore MACOSX_BUNDLE
        src/main.mm src/AppDelegate.mm src/TranslationPanel.mm src/SettingsViewController.mm src/LoreAppearance.mm
        src/LoreMascotView.mm
        src/ShortcutMonitor.mm src/ShortcutPreferences.mm src/ModelStore.mm
        ${LORE_UI_RESOURCES} resources/AppIcon.icns resources/THIRD_PARTY_NOTICES.md "${llama_SOURCE_DIR}/LICENSE")
    set_source_files_properties(${LORE_UI_RESOURCES} resources/AppIcon.icns resources/THIRD_PARTY_NOTICES.md "${llama_SOURCE_DIR}/LICENSE"
        PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
    target_link_libraries(Lore PRIVATE lore_engine lore_gesture
        "-framework AppKit" "-framework Foundation" "-framework QuartzCore"
        "-framework CoreGraphics" "-framework ServiceManagement" "-framework ImageIO"
        "-framework ApplicationServices" "-framework Carbon")
    target_compile_options(Lore PRIVATE -fobjc-arc -Wall -Wextra)
    set_target_properties(Lore PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/resources/Info.plist.in"
        MACOSX_BUNDLE_GUI_IDENTIFIER local.lore.Lore
        MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
    set(LORE_SIGNING_IDENTITY "-" CACHE STRING "Codesign identity; '-' is ad-hoc signing for personal use")
    add_custom_command(TARGET Lore POST_BUILD
        COMMAND /usr/bin/codesign --force --sign "${LORE_SIGNING_IDENTITY}" "$<TARGET_BUNDLE_DIR:Lore>"
        COMMENT "Signing Lore.app" VERBATIM)
endif()

if(LORE_BUILD_TESTS)
    enable_testing()
    add_executable(gesture_tests tests/gesture_tests.cpp)
    target_link_libraries(gesture_tests PRIVATE lore_gesture)
    add_test(NAME copy_gesture COMMAND gesture_tests)
    add_executable(shortcut_tests tests/shortcut_tests.cpp)
    target_link_libraries(shortcut_tests PRIVATE lore_gesture)
    add_test(NAME shortcuts COMMAND shortcut_tests)
    add_executable(short_input_tests tests/short_input_tests.cpp)
    target_include_directories(short_input_tests PRIVATE src)
    add_test(NAME short_english_input COMMAND short_input_tests)
    if(APPLE)
        add_executable(shortcut_preferences_tests tests/shortcut_preferences_tests.mm src/ShortcutPreferences.mm)
        target_link_libraries(shortcut_preferences_tests PRIVATE lore_gesture
            "-framework AppKit" "-framework Foundation" "-framework Carbon")
        target_compile_options(shortcut_preferences_tests PRIVATE -fobjc-arc -Wall -Wextra)
        add_test(NAME shortcut_preferences COMMAND shortcut_preferences_tests)
        file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/test-resources")
        foreach(resource IN LISTS LORE_UI_RESOURCES)
            get_filename_component(resource_name "${resource}" NAME)
            configure_file("${resource}" "${CMAKE_BINARY_DIR}/test-resources/${resource_name}" COPYONLY)
        endforeach()
        add_executable(panel_smoke tests/panel_smoke.mm src/TranslationPanel.mm src/LoreAppearance.mm src/LoreMascotView.mm)
        target_include_directories(panel_smoke PRIVATE src)
        target_compile_definitions(panel_smoke PRIVATE
            LORE_TEST_RESOURCE_DIR="${CMAKE_BINARY_DIR}/test-resources")
        target_link_libraries(panel_smoke PRIVATE "-framework AppKit" "-framework QuartzCore" "-framework ImageIO")
        target_compile_options(panel_smoke PRIVATE -fobjc-arc -Wall -Wextra)
        add_test(NAME translation_panel COMMAND panel_smoke)
        set_tests_properties(translation_panel PROPERTIES
            WORKING_DIRECTORY "${CMAKE_BINARY_DIR}" TIMEOUT 90)
        add_executable(settings_smoke tests/settings_smoke.mm src/SettingsViewController.mm src/TranslationPanel.mm src/LoreAppearance.mm
            src/LoreMascotView.mm
            src/ShortcutPreferences.mm src/ShortcutMonitor.mm)
        target_include_directories(settings_smoke PRIVATE src)
        target_compile_definitions(settings_smoke PRIVATE
            LORE_TEST_RESOURCE_DIR="${CMAKE_BINARY_DIR}/test-resources")
        target_link_libraries(settings_smoke PRIVATE lore_gesture "-framework AppKit" "-framework QuartzCore" "-framework ServiceManagement"
            "-framework CoreGraphics" "-framework ApplicationServices" "-framework Carbon" "-framework ImageIO")
        target_compile_options(settings_smoke PRIVATE -fobjc-arc -Wall -Wextra)
        add_test(NAME settings_navigation COMMAND settings_smoke)
        set_tests_properties(settings_navigation PROPERTIES
            WORKING_DIRECTORY "${CMAKE_BINARY_DIR}" TIMEOUT 30)
        add_executable(mascot_smoke tests/mascot_smoke.mm src/LoreMascotView.mm src/LoreAppearance.mm)
        target_include_directories(mascot_smoke PRIVATE src)
        target_compile_definitions(mascot_smoke PRIVATE
            LORE_TEST_RESOURCE_DIR="${CMAKE_BINARY_DIR}/test-resources")
        target_link_libraries(mascot_smoke PRIVATE "-framework AppKit" "-framework QuartzCore" "-framework ImageIO")
        target_compile_options(mascot_smoke PRIVATE -fobjc-arc -Wall -Wextra)
        add_test(NAME mascot_hover COMMAND mascot_smoke)
        set_tests_properties(mascot_hover PROPERTIES
            WORKING_DIRECTORY "${CMAKE_BINARY_DIR}" TIMEOUT 15)
    endif()
endif()
if(LORE_BUILD_SMOKE)
    add_executable(engine_smoke tests/engine_smoke.cpp)
    target_link_libraries(engine_smoke PRIVATE lore_engine)
    add_executable(engine_profile tests/engine_profile.cpp)
    target_link_libraries(engine_profile PRIVATE lore_engine)
    # The exact production engine, compiled with an evaluation-only prompt seam.
    # No candidate switches or experiment code are linked into Lore.app.
    add_library(lore_engine_evaluation STATIC src/TranslationEngine.cpp)
    target_compile_definitions(lore_engine_evaluation PRIVATE LORE_EVALUATE_PROMPTS=1)
    target_include_directories(lore_engine_evaluation PRIVATE tests PUBLIC src)
    target_link_libraries(lore_engine_evaluation PUBLIC llama Threads::Threads)
    target_compile_options(lore_engine_evaluation PRIVATE -Wall -Wextra -Wpedantic)
    add_executable(engine_evaluate tests/engine_evaluate.cpp)
    target_link_libraries(engine_evaluate PRIVATE lore_engine_evaluation)
    add_executable(engine_evaluate_production tests/engine_evaluate.cpp)
    target_link_libraries(engine_evaluate_production PRIVATE lore_engine)
endif()
