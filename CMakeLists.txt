cmake_minimum_required(VERSION 3.24)

if(CMAKE_HOST_APPLE OR CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS version")
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Target architecture")
endif()
project(Bawan VERSION 1.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()
option(BAWAN_BUILD_APP "Build the macOS menu bar application" ${APPLE})
option(BAWAN_BUILD_TESTS "Build Bawan's behavior tests and macOS panel smoke test" OFF)
option(BAWAN_BUILD_SMOKE "Build the real-model inference smoke test" OFF)
option(BAWAN_WARNINGS_AS_ERRORS "Fail the build on warnings in Bawan's own sources" OFF)
option(BAWAN_ENABLE_SANITIZERS "Build Bawan's own code and tests with ASan and UBSan" OFF)
option(BAWAN_ENABLE_UPDATES "Include Sparkle automatic update checks" OFF)
set(BAWAN_BUILD_NUMBER "" CACHE STRING "Monotonically increasing CFBundleVersion; empty uses the project version")
if(BAWAN_BUILD_NUMBER STREQUAL "")
    set(BAWAN_BUILD_NUMBER "${PROJECT_VERSION}")
endif()
if(NOT BAWAN_BUILD_NUMBER MATCHES "^[0-9]+([.][0-9]+)?([.][0-9]+)?$")
    message(FATAL_ERROR "BAWAN_BUILD_NUMBER must contain one to three nonnegative integers separated by periods.")
endif()
set(BAWAN_SIGNING_IDENTITY "-" CACHE STRING "Codesign identity; '-' is ad-hoc signing for personal use")
include(cmake/BawanUpdates.cmake)

# Enable native languages before configuring Metal's .m sources in llama.cpp.
# Enabling OBJCXX after add_subdirectory leaves its compile rule unavailable
# in dependency directories when CMake generates the build system.
if(APPLE)
    enable_language(OBJC OBJCXX)
    set(CMAKE_OBJCXX_STANDARD 17)
    set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
endif()

if(BAWAN_BUILD_APP AND NOT APPLE)
    message(FATAL_ERROR "Bawan.app requires macOS 14+, Apple's SDK and an Apple Silicon Mac. Use -DBAWAN_BUILD_APP=OFF for portable engine checks.")
endif()

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_CCACHE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_RPC OFF CACHE BOOL "" FORCE)
set(GGML_METAL ${APPLE} CACHE BOOL "" FORCE)
option(BAWAN_PRECOMPILED_METAL "Ship precompiled Metal kernels (needs Xcode's Metal compiler)" ${APPLE})
if(BAWAN_PRECOMPILED_METAL)
    execute_process(COMMAND xcrun -sdk macosx metal --version
        RESULT_VARIABLE BAWAN_METAL_COMPILER_STATUS OUTPUT_QUIET ERROR_QUIET)
    if(NOT BAWAN_METAL_COMPILER_STATUS EQUAL 0)
        message(FATAL_ERROR "BAWAN_PRECOMPILED_METAL needs Xcode's Metal compiler (xcrun metal). Select Xcode and install the Metal Toolchain with xcodebuild -downloadComponent MetalToolchain if needed. With Command Line Tools, configure with -DBAWAN_PRECOMPILED_METAL=OFF to compile kernels at runtime; that build keeps ~30 MiB more after the model unloads and exceeds scripts/memory-budget.json.")
    endif()
endif()
if(BAWAN_PRECOMPILED_METAL)
    set(GGML_METAL_EMBED_LIBRARY OFF CACHE BOOL "" FORCE)
else()
    set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "" FORCE)
endif()
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

# Directory-scoped so they reach only the Bawan targets declared below, not llama.cpp.
if(BAWAN_WARNINGS_AS_ERRORS)
    add_compile_options(-Werror)
endif()
if(BAWAN_ENABLE_SANITIZERS)
    add_compile_options(-fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer)
    add_link_options(-fsanitize=address,undefined)
endif()

find_package(Threads REQUIRED)

function(bawan_stage_metal_libraries target destination)
    set(staged_files)
    foreach(library IN LISTS BAWAN_METAL_LIBRARIES)
        get_filename_component(name "${library}" NAME)
        set(output "${destination}/${name}")
        if(output STREQUAL library)
            continue()
        endif()
        add_custom_command(OUTPUT "${output}"
            COMMAND ${CMAKE_COMMAND} -E make_directory "${destination}"
            COMMAND ${CMAKE_COMMAND} -E copy "${library}" "${output}"
            DEPENDS "${library}"
            VERBATIM)
        list(APPEND staged_files "${output}")
    endforeach()
    add_custom_target(${target} DEPENDS ${staged_files})
    add_dependencies(${target} ggml-metal-lib)
    if(ARGV2)
        set(${ARGV2} "${staged_files}" PARENT_SCOPE)
    endif()
endfunction()

if(BAWAN_PRECOMPILED_METAL)
    get_directory_property(BAWAN_METAL_LIBRARIES
        DIRECTORY "${llama_SOURCE_DIR}/ggml/src/ggml-metal" DEFINITION METALLIB_FILES)
    if(NOT BAWAN_METAL_LIBRARIES)
        message(FATAL_ERROR "llama.cpp did not configure any precompiled Metal libraries.")
    endif()
    if(CMAKE_CONFIGURATION_TYPES)
        set(BAWAN_CONFIGURATION_DIR "/$<CONFIG>")
    endif()
    if(BAWAN_BUILD_TESTS OR BAWAN_BUILD_SMOKE)
        set(BAWAN_TOOL_OUTPUT_DIR "${CMAKE_CURRENT_BINARY_DIR}${BAWAN_CONFIGURATION_DIR}")
        if(CMAKE_RUNTIME_OUTPUT_DIRECTORY)
            cmake_path(ABSOLUTE_PATH CMAKE_RUNTIME_OUTPUT_DIRECTORY NORMALIZE
                BASE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}" OUTPUT_VARIABLE BAWAN_TOOL_OUTPUT_DIR)
            if(NOT BAWAN_TOOL_OUTPUT_DIR MATCHES "[$]<")
                string(APPEND BAWAN_TOOL_OUTPUT_DIR "${BAWAN_CONFIGURATION_DIR}")
            endif()
        endif()
        bawan_stage_metal_libraries(bawan_tool_metal_libraries "${BAWAN_TOOL_OUTPUT_DIR}")
    endif()
endif()

function(bawan_use_tool_metal_libraries target)
    if(BAWAN_PRECOMPILED_METAL)
        add_dependencies(${target} bawan_tool_metal_libraries)
    endif()
endfunction()

add_library(bawan_engine STATIC src/TranslationEngine.cpp)
target_include_directories(bawan_engine PUBLIC src)
target_link_libraries(bawan_engine PUBLIC llama Threads::Threads)
target_compile_options(bawan_engine PRIVATE -Wall -Wextra -Wpedantic)

add_library(bawan_gesture STATIC src/ShortcutBinding.cpp)
target_include_directories(bawan_gesture PUBLIC src)
target_compile_options(bawan_gesture PRIVATE -Wall -Wextra -Wpedantic)

set(BAWAN_UI_RESOURCES resources/BawanMascot.png resources/PaperGrain.png)
set(BAWAN_MODEL_SOURCES src/ModelStore.mm src/ModelDownloader.mm src/ModelVerification.mm)

if(APPLE AND (BAWAN_BUILD_APP OR BAWAN_BUILD_TESTS))
    # Separate app/test archives keep compile-time resource paths consistent,
    # including the inline image helpers in BawanAppearance.h.
    function(add_bawan_ui target)
        add_library(${target} STATIC
            src/TranslationPanel.mm src/BawanChrome.mm src/SettingsViewController.mm
            src/BawanAppearance.mm src/BawanMascotView.mm
            src/ShortcutMonitor.mm src/SelectionReader.mm src/ShortcutPreferences.mm
            src/SetupUI.mm src/OnboardingViewController.mm)
        target_include_directories(${target} PUBLIC src)
        target_link_libraries(${target} PUBLIC bawan_gesture
            "-framework AppKit" "-framework Foundation" "-framework QuartzCore"
            "-framework CoreGraphics" "-framework ImageIO"
            "-framework ApplicationServices" "-framework Carbon")
        target_compile_options(${target} PUBLIC -fobjc-arc -Wall -Wextra)
    endfunction()
endif()

if(BAWAN_BUILD_APP)
    add_bawan_ui(bawan_ui)
    configure_file(LICENSE "${CMAKE_CURRENT_BINARY_DIR}/BAWAN-LICENSE.txt" COPYONLY)
    set(BAWAN_LICENSE_RESOURCES resources/THIRD_PARTY_NOTICES.md resources/MODEL_USAGE.md
        "${CMAKE_CURRENT_BINARY_DIR}/BAWAN-LICENSE.txt" "${llama_SOURCE_DIR}/LICENSE")
    add_executable(BawanApp MACOSX_BUNDLE
        src/main.mm src/AppDelegate.mm src/MemoryProbe.mm ${BAWAN_MODEL_SOURCES} src/EngineHost.mm src/TranslationSession.cpp
        ${BAWAN_UI_RESOURCES} resources/AppIcon.icns resources/StatusItemTemplate.pdf
        ${BAWAN_LICENSE_RESOURCES})
    set_source_files_properties(${BAWAN_UI_RESOURCES} resources/AppIcon.icns resources/StatusItemTemplate.pdf
        ${BAWAN_LICENSE_RESOURCES}
        PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
    target_link_libraries(BawanApp PRIVATE bawan_ui bawan_engine "-framework ServiceManagement")
    set_target_properties(BawanApp PROPERTIES
        OUTPUT_NAME Bawan
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/resources/Info.plist.in"
        MACOSX_BUNDLE_GUI_IDENTIFIER local.bawan.Bawan
        MACOSX_BUNDLE_BUNDLE_VERSION "${BAWAN_BUILD_NUMBER}"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
    bawan_link_updater(BawanApp)
    set_target_properties(BawanApp PROPERTIES BUILD_WITH_INSTALL_RPATH TRUE
        INSTALL_RPATH "@executable_path/../Frameworks")
    if(BAWAN_PRECOMPILED_METAL)
        bawan_stage_metal_libraries(bawan_app_metal_libraries
            "${CMAKE_BINARY_DIR}${BAWAN_CONFIGURATION_DIR}/Bawan.app/Contents/Resources")
        add_dependencies(BawanApp bawan_app_metal_libraries)
    endif()
    add_custom_target(Bawan ALL
        COMMAND "${CMAKE_COMMAND}" "-DAPP_BUNDLE=$<TARGET_BUNDLE_DIR:BawanApp>"
            "-DSIGNING_IDENTITY=${BAWAN_SIGNING_IDENTITY}"
            "-DSPARKLE_FRAMEWORK=${BAWAN_SPARKLE_FRAMEWORK}"
            -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/SignBundle.cmake"
        DEPENDS BawanApp
        COMMENT "Signing Bawan.app" VERBATIM)
endif()

if(BAWAN_BUILD_TESTS)
    enable_testing()
    add_executable(model_download_tests tests/model_download_tests.cpp)
    target_include_directories(model_download_tests PRIVATE src)
    target_compile_options(model_download_tests PRIVATE -Wall -Wextra -Wpedantic)
    add_test(NAME model_download_response COMMAND model_download_tests)
    add_executable(engine_event_mailbox_tests tests/engine_event_mailbox_tests.cpp)
    target_include_directories(engine_event_mailbox_tests PRIVATE src)
    target_link_libraries(engine_event_mailbox_tests PRIVATE Threads::Threads)
    add_test(NAME engine_event_mailbox COMMAND engine_event_mailbox_tests)
    add_executable(translation_session_tests tests/translation_session_tests.cpp src/TranslationSession.cpp)
    target_include_directories(translation_session_tests PRIVATE src)
    target_compile_options(translation_session_tests PRIVATE -Wall -Wextra -Wpedantic)
    add_test(NAME translation_session COMMAND translation_session_tests)
    add_executable(shortcut_tests tests/shortcut_tests.cpp)
    target_link_libraries(shortcut_tests PRIVATE bawan_gesture)
    add_test(NAME shortcuts COMMAND shortcut_tests)
    add_executable(short_input_tests tests/short_input_tests.cpp)
    target_include_directories(short_input_tests PRIVATE src)
    add_test(NAME short_english_input COMMAND short_input_tests)
    add_executable(utf8_tests tests/utf8_tests.cpp)
    target_include_directories(utf8_tests PRIVATE src)
    add_test(NAME utf8 COMMAND utf8_tests)
    add_executable(engine_lifecycle tests/engine_lifecycle.cpp)
    target_link_libraries(engine_lifecycle PRIVATE bawan_engine)
    bawan_use_tool_metal_libraries(engine_lifecycle)
    add_test(NAME engine_lifecycle COMMAND engine_lifecycle)
    set_tests_properties(engine_lifecycle PROPERTIES TIMEOUT 120)
    if(APPLE)
        add_bawan_ui(bawan_ui_test)
        target_compile_definitions(bawan_ui_test PUBLIC
            BAWAN_TEST_RESOURCE_DIR="${CMAKE_BINARY_DIR}/test-resources")
        add_executable(model_store_tests tests/model_store_tests.mm ${BAWAN_MODEL_SOURCES})
        target_include_directories(model_store_tests PRIVATE src)
        target_link_libraries(model_store_tests PRIVATE "-framework Foundation")
        target_compile_options(model_store_tests PRIVATE -fobjc-arc -Wall -Wextra)
        add_test(NAME model_store COMMAND model_store_tests)
        set_tests_properties(model_store PROPERTIES TIMEOUT 90)
        add_executable(shortcut_preferences_tests tests/shortcut_preferences_tests.mm)
        target_link_libraries(shortcut_preferences_tests PRIVATE bawan_ui_test)
        add_test(NAME shortcut_preferences COMMAND shortcut_preferences_tests)
        add_executable(selection_reader_tests tests/selection_reader_tests.mm)
        target_link_libraries(selection_reader_tests PRIVATE bawan_ui_test)
        add_test(NAME selection_reader COMMAND selection_reader_tests)
        add_executable(shortcut_monitor_tests tests/shortcut_monitor_tests.mm)
        target_link_libraries(shortcut_monitor_tests PRIVATE bawan_ui_test)
        add_test(NAME shortcut_monitor COMMAND shortcut_monitor_tests)
        add_executable(model_setup_state_tests tests/model_setup_state_tests.mm)
        target_include_directories(model_setup_state_tests PRIVATE src)
        target_link_libraries(model_setup_state_tests PRIVATE "-framework Foundation")
        target_compile_options(model_setup_state_tests PRIVATE -fobjc-arc -Wall -Wextra)
        add_test(NAME model_setup_state COMMAND model_setup_state_tests)
        file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/test-resources")
        foreach(resource IN LISTS BAWAN_UI_RESOURCES)
            get_filename_component(resource_name "${resource}" NAME)
            configure_file("${resource}" "${CMAKE_BINARY_DIR}/test-resources/${resource_name}" COPYONLY)
        endforeach()
        add_executable(panel_smoke tests/panel_smoke.mm)
        target_link_libraries(panel_smoke PRIVATE bawan_ui_test)
        add_test(NAME translation_panel COMMAND panel_smoke)
        set_tests_properties(translation_panel PROPERTIES
            WORKING_DIRECTORY "${CMAKE_BINARY_DIR}" TIMEOUT 90)
        add_executable(settings_smoke tests/settings_smoke.mm)
        target_link_libraries(settings_smoke PRIVATE bawan_ui_test)
        add_test(NAME settings_navigation COMMAND settings_smoke)
        set_tests_properties(settings_navigation PROPERTIES
            WORKING_DIRECTORY "${CMAKE_BINARY_DIR}" TIMEOUT 30)
        add_executable(onboarding_smoke tests/onboarding_smoke.mm)
        target_link_libraries(onboarding_smoke PRIVATE bawan_ui_test)
        add_test(NAME onboarding COMMAND onboarding_smoke -AppleShowScrollBars Always)
        set_tests_properties(onboarding PROPERTIES
            WORKING_DIRECTORY "${CMAKE_BINARY_DIR}" TIMEOUT 45)
        file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/onboarding-when-scrolling")
        add_test(NAME onboarding_when_scrolling COMMAND onboarding_smoke -AppleShowScrollBars WhenScrolling)
        set_tests_properties(onboarding_when_scrolling PROPERTIES
            WORKING_DIRECTORY "${CMAKE_BINARY_DIR}/onboarding-when-scrolling" TIMEOUT 45)
        add_executable(app_delegate_smoke tests/app_delegate_smoke.mm
            src/AppDelegate.mm src/MemoryProbe.mm ${BAWAN_MODEL_SOURCES} src/EngineHost.mm src/TranslationSession.cpp)
        target_link_libraries(app_delegate_smoke PRIVATE bawan_ui_test bawan_engine "-framework ServiceManagement")
        bawan_use_tool_metal_libraries(app_delegate_smoke)
        bawan_link_updater(app_delegate_smoke)
        add_test(NAME app_delegate_smoke COMMAND app_delegate_smoke)
        set_tests_properties(app_delegate_smoke PROPERTIES
            WORKING_DIRECTORY "${CMAKE_BINARY_DIR}" TIMEOUT 60)
        if(BAWAN_ENABLE_UPDATES)
            add_test(NAME app_delegate_update_termination COMMAND app_delegate_smoke --update-termination-probe)
            set_tests_properties(app_delegate_update_termination PROPERTIES
                WORKING_DIRECTORY "${CMAKE_BINARY_DIR}" TIMEOUT 15)
            add_test(NAME app_delegate_update_termination_behavior COMMAND app_delegate_smoke --update-termination-behavior)
            set_tests_properties(app_delegate_update_termination_behavior PROPERTIES
                WORKING_DIRECTORY "${CMAKE_BINARY_DIR}" TIMEOUT 60)
        endif()
        add_test(NAME onboarding_selection_trial COMMAND app_delegate_smoke --selection-trial)
        set_tests_properties(onboarding_selection_trial PROPERTIES
            WORKING_DIRECTORY "${CMAKE_BINARY_DIR}" TIMEOUT 60)
        add_executable(mascot_smoke tests/mascot_smoke.mm)
        target_link_libraries(mascot_smoke PRIVATE bawan_ui_test)
        add_test(NAME mascot_hover COMMAND mascot_smoke)
        set_tests_properties(mascot_hover PROPERTIES
            WORKING_DIRECTORY "${CMAKE_BINARY_DIR}" TIMEOUT 15)
        add_executable(progress_smoke tests/progress_smoke.mm)
        target_link_libraries(progress_smoke PRIVATE bawan_ui_test)
        add_test(NAME progress_motion COMMAND progress_smoke)
        set_tests_properties(progress_motion PROPERTIES
            WORKING_DIRECTORY "${CMAKE_BINARY_DIR}" TIMEOUT 20)
    endif()
endif()
if(BAWAN_BUILD_SMOKE)
    add_executable(engine_smoke tests/engine_smoke.cpp)
    target_link_libraries(engine_smoke PRIVATE bawan_engine)
    bawan_use_tool_metal_libraries(engine_smoke)
    add_executable(engine_profile tests/engine_profile.cpp)
    target_link_libraries(engine_profile PRIVATE bawan_engine)
    bawan_use_tool_metal_libraries(engine_profile)
endif()
