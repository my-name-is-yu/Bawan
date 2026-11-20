if(NOT IS_DIRECTORY "${APP_BUNDLE}" OR NOT DEFINED SIGNING_IDENTITY)
    message(FATAL_ERROR "APP_BUNDLE and SIGNING_IDENTITY are required.")
endif()

set(sign_options --force --sign "${SIGNING_IDENTITY}")
if(SIGNING_IDENTITY MATCHES "^Developer ID Application:")
    list(APPEND sign_options --options runtime --timestamp)
endif()

function(sign_code path)
    execute_process(COMMAND /usr/bin/codesign ${sign_options} "${path}"
        COMMAND_ERROR_IS_FATAL ANY)
endfunction()

set(embedded "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework")
file(REMOVE_RECURSE "${embedded}")
if(SPARKLE_FRAMEWORK)
    file(MAKE_DIRECTORY "${APP_BUNDLE}/Contents/Frameworks")
    # ditto preserves framework symlinks and nested executable permissions.
    execute_process(COMMAND /usr/bin/ditto "${SPARKLE_FRAMEWORK}" "${embedded}"
        COMMAND_ERROR_IS_FATAL ANY)
    set(version "${embedded}/Versions/B")
    foreach(component XPCServices/Downloader.xpc XPCServices/Installer.xpc Autoupdate Updater.app)
        sign_code("${version}/${component}")
    endforeach()
    sign_code("${embedded}")
endif()
sign_code("${APP_BUNDLE}")
execute_process(COMMAND /usr/bin/codesign --verify --deep --strict "${APP_BUNDLE}"
    COMMAND_ERROR_IS_FATAL ANY)
