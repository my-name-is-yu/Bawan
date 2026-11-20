set(BAWAN_UPDATE_FEED_URL "https://github.com/my-name-is-yu/Bawan/releases/latest/download/appcast.xml"
    CACHE STRING "HTTPS Sparkle appcast URL")
set(BAWAN_SPARKLE_PUBLIC_KEY "$ENV{BAWAN_SPARKLE_PUBLIC_KEY}" CACHE STRING "Base64 Ed25519 public key for update archives")
if(BAWAN_SPARKLE_PUBLIC_KEY STREQUAL "" AND DEFINED ENV{BAWAN_SPARKLE_PUBLIC_KEY})
    set(BAWAN_SPARKLE_PUBLIC_KEY "$ENV{BAWAN_SPARKLE_PUBLIC_KEY}")
endif()
set(BAWAN_UPDATE_PLIST "")
set(BAWAN_SPARKLE_FRAMEWORK "")

if(BAWAN_ENABLE_UPDATES)
    if(NOT APPLE OR NOT BAWAN_BUILD_APP)
        message(FATAL_ERROR "Sparkle updates require BAWAN_BUILD_APP on macOS.")
    endif()
    if(NOT BAWAN_UPDATE_FEED_URL MATCHES "^https://[^\"<> \t\n]+$")
        message(FATAL_ERROR "BAWAN_UPDATE_FEED_URL must be an HTTPS URL.")
    endif()
    string(LENGTH "${BAWAN_SPARKLE_PUBLIC_KEY}" key_length)
    if(NOT key_length EQUAL 44 OR NOT BAWAN_SPARKLE_PUBLIC_KEY MATCHES "^[A-Za-z0-9+/]+=$")
        message(FATAL_ERROR "Set BAWAN_SPARKLE_PUBLIC_KEY to your 32-byte base64 Ed25519 public key.")
    endif()
    include(FetchContent)
    FetchContent_Declare(sparkle
        URL https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz
        URL_HASH SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
    FetchContent_MakeAvailable(sparkle)
    set(BAWAN_SPARKLE_FRAMEWORK "${sparkle_SOURCE_DIR}/Sparkle.framework")
    configure_file("${sparkle_SOURCE_DIR}/LICENSE" "${CMAKE_BINARY_DIR}/Sparkle-LICENSE.txt" COPYONLY)
    add_library(Sparkle::Sparkle SHARED IMPORTED GLOBAL)
    set_target_properties(Sparkle::Sparkle PROPERTIES
        IMPORTED_LOCATION "${BAWAN_SPARKLE_FRAMEWORK}/Sparkle"
        FRAMEWORK TRUE)
    string(REPLACE "&" "&amp;" escaped_feed_url "${BAWAN_UPDATE_FEED_URL}")
    set(BAWAN_UPDATE_PLIST "
    <key>SUFeedURL</key><string>${escaped_feed_url}</string>
    <key>SUPublicEDKey</key><string>${BAWAN_SPARKLE_PUBLIC_KEY}</string>
    <key>SUEnableAutomaticChecks</key><false/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <key>SUAllowsAutomaticUpdates</key><false/>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
    <key>SUSendProfileInfo</key><false/>")
endif()

function(bawan_link_updater target)
    target_sources(${target} PRIVATE src/AppUpdater.mm)
    target_compile_definitions(${target} PRIVATE BAWAN_ENABLE_UPDATES=$<BOOL:${BAWAN_ENABLE_UPDATES}>)
    if(BAWAN_ENABLE_UPDATES)
        target_link_libraries(${target} PRIVATE Sparkle::Sparkle)
        target_compile_options(${target} PRIVATE "-F${sparkle_SOURCE_DIR}")
        set_property(TARGET ${target} APPEND PROPERTY BUILD_RPATH "${sparkle_SOURCE_DIR}")
        get_target_property(is_bundle ${target} MACOSX_BUNDLE)
        if(is_bundle)
            target_sources(${target} PRIVATE "${CMAKE_BINARY_DIR}/Sparkle-LICENSE.txt")
            set_source_files_properties("${CMAKE_BINARY_DIR}/Sparkle-LICENSE.txt"
                PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
        endif()
    endif()
endfunction()
