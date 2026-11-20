#!/bin/sh
set -eu

fail() { printf '%s\n' "$*" >&2; exit 1; }

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] ||
    fail 'Release preparation requires an Apple Silicon Mac.'

: "${BAWAN_SIGNING_IDENTITY:?Set BAWAN_SIGNING_IDENTITY to your Developer ID Application identity.}"
: "${BAWAN_SPARKLE_PUBLIC_KEY:?Set BAWAN_SPARKLE_PUBLIC_KEY to your Sparkle public key.}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool Keychain profile name.}"
case "$BAWAN_SIGNING_IDENTITY" in
    'Developer ID Application: '*) ;;
    *) fail 'A Developer ID Application identity is required; development and ad-hoc signing cannot produce a release.' ;;
esac
security find-identity -v -p codesigning |
    awk -v wanted="$BAWAN_SIGNING_IDENTITY" 'index($0, "\"" wanted "\"") { found=1 } END { exit !found }' ||
    fail 'The specified Developer ID Application identity and private key are not available in the Keychain.'

default_feed_url=https://github.com/my-name-is-yu/Bawan/releases/latest/download/appcast.xml
feed_url=${BAWAN_UPDATE_FEED_URL:-$default_feed_url}
case "$feed_url" in
    https://*) ;;
    *) fail 'BAWAN_UPDATE_FEED_URL must use HTTPS.' ;;
esac
key_account=${BAWAN_SPARKLE_KEY_ACCOUNT:-bawan-updates}
build_dir="$repo_dir/build/release"

command -v cmake >/dev/null || fail 'CMake is required.'
xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null

set -- -S "$repo_dir" -B "$build_dir" -DCMAKE_BUILD_TYPE=Release \
    -DBAWAN_BUILD_APP=ON -DBAWAN_BUILD_TESTS=OFF -DBAWAN_ENABLE_UPDATES=ON \
    "-DBAWAN_SIGNING_IDENTITY=$BAWAN_SIGNING_IDENTITY" \
    "-DBAWAN_SPARKLE_PUBLIC_KEY=$BAWAN_SPARKLE_PUBLIC_KEY" \
    "-DBAWAN_UPDATE_FEED_URL=$feed_url"
if [ -n "${BAWAN_BUILD_NUMBER:-}" ]; then
    set -- "$@" "-DBAWAN_BUILD_NUMBER=$BAWAN_BUILD_NUMBER"
else
    set -- "$@" -U BAWAN_BUILD_NUMBER
fi
cmake "$@"
cmake --build "$build_dir" --target Bawan --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-3}"

app="$build_dir/Bawan.app"
tools_dir="$build_dir/_deps/sparkle-src/bin"
[ -x "$tools_dir/generate_keys" ] && [ -x "$tools_dir/generate_appcast" ] ||
    fail 'The Sparkle release tools are missing from the build directory.'
public_key=$("$tools_dir/generate_keys" --account "$key_account" -p)
[ "$public_key" = "$BAWAN_SPARKLE_PUBLIC_KEY" ] ||
    fail 'The Sparkle key in the Keychain does not match the public key embedded in the app.'

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
case "$version:$build_number" in
    *[!0-9.:]*) fail 'Release version and build number must contain only digits and periods.' ;;
esac
download_url_prefix=${BAWAN_UPDATE_DOWNLOAD_URL_PREFIX:-}
if [ -z "$download_url_prefix" ]; then
    if [ "$feed_url" = "$default_feed_url" ]; then
        download_url_prefix="https://github.com/my-name-is-yu/Bawan/releases/download/v$version/"
    else
        feed_path=${feed_url%%[?#]*}
        download_url_prefix="${feed_path%/*}/"
    fi
fi
case "$download_url_prefix" in
    https://?*/) ;;
    *) fail 'BAWAN_UPDATE_DOWNLOAD_URL_PREFIX must be an HTTPS directory URL ending with a slash.' ;;
esac

output_root="$repo_dir/build/release-artifacts"
output_dir="$output_root/$version-$build_number"
[ ! -e "$output_dir" ] || fail "Release artifacts already exist: $output_dir"
mkdir -p "$output_root"
staging_dir=$(mktemp -d "$output_root/.prepare.XXXXXX")
trap 'rm -rf -- "$staging_dir"' EXIT HUP INT TERM

codesign --verify --deep --strict --verbose=2 "$app"
codesign --display --verbose=2 "$app" 2>&1 |
    awk '/^Authority=Developer ID Application:/ { found=1 } END { exit !found }' ||
    fail 'The built app does not have a Developer ID Application signature.'

submission_zip="$staging_dir/notarization.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$submission_zip"
notary_result="$build_dir/notarization-result.plist"
xcrun notarytool submit "$submission_zip" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format plist > "$notary_result"
notary_status=$(/usr/libexec/PlistBuddy -c 'Print :status' "$notary_result")
[ "$notary_status" = Accepted ] ||
    fail "Notarization status: $notary_status. See $notary_result for the submission ID and request its notarytool log."
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict --verbose=2 "$app"
spctl --assess --type execute --verbose=2 "$app"
rm -- "$submission_zip"

archive_name="Bawan-$version-macOS-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging_dir/$archive_name"
"$tools_dir/generate_appcast" --account "$key_account" --maximum-deltas 0 \
    --download-url-prefix "$download_url_prefix" \
    -o "$staging_dir/appcast.xml" "$staging_dir"
xmllint --noout "$staging_dir/appcast.xml"
[ "$(xmllint --xpath "boolean(//*[local-name()='enclosure'][@*[local-name()='edSignature']])" "$staging_dir/appcast.xml")" = true ] ||
    fail 'The generated appcast does not contain a signed update.'
(cd "$staging_dir" && shasum -a 256 "$archive_name" > SHA256SUMS)
mv "$staging_dir" "$output_dir"
trap - EXIT HUP INT TERM

printf '\nPrepared release files: %s\n' "$output_dir"
printf '%s\n' 'Verify the signed old-to-new update and shortcut permissions before publishing.'
printf '%s\n' 'Nothing has been published to GitHub.'
