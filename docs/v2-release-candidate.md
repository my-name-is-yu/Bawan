# v2.0.0-rc.1 release-candidate handoff

This is a release handoff, not a built or signed candidate. No tag or public release is created by these instructions.

## Source and versions

After review, use the approved PR head and re-freeze that exact source before building. Do not substitute an earlier commit or treat earlier-commit evidence as candidate evidence.

The planned label is v2.0.0-rc.1. The short version is numeric 2.0.0; BAWAN_BUILD_NUMBER remains generic and defaults to the project version when unset. Build the signed update baseline as short version/build 2.0.0/2.0.0, then the RC as 2.0.0/2.0.1. Both build numbers exceed the previously signed 1.1.904. A later stable 2.0.0 release must explicitly use build 2.0.2 or greater. The CMake metadata change changes app metadata; do not claim an identical binary to a separately memory-measured build. Memory remains a separate owner gate.

Fill in the full approved PR-head SHA before running this checkout block. It refuses a dirty checkout and cannot switch unless FETCH_HEAD matches:

```sh
(
  set -eu
  PR_BRANCH='devin/1795182518-v2-rc-handoff'
  REVIEWED_SHA='approved-40-character-PR-head-sha'
  test -z "$(git status --porcelain)"
  git fetch origin "$PR_BRANCH"
  FETCHED_SHA=$(git rev-parse --verify FETCH_HEAD)
  printf 'Fetched PR SHA: %s\n' "$FETCHED_SHA"
  test "$FETCHED_SHA" = "$REVIEWED_SHA"
  git switch --detach "$FETCHED_SHA"
  test "$(git rev-parse HEAD)" = "$REVIEWED_SHA"
  test -z "$(git status --porcelain)"
)
```

## Owner-run signed builds

Run release builds only on an already-authorized signing environment with the existing Developer ID private key, notary profile, and Sparkle key in its Keychain. Do not export private keys, generate replacement keys, or use another person's Mac. scripts/release.sh uploads a temporary ZIP containing the signed app to Apple's notarization service and waits for Accepted. This is a network upload to Apple, not publication to GitHub or the test feed. The app bundle does not include the downloaded model; ModelStore stores it in the user's Application Support directory. The model and private signing keys are not sent.

Use the existing Developer ID identity and retrieve only the existing Sparkle public key:

```sh
export BAWAN_SIGNING_IDENTITY='Developer ID Application: existing identity'
SPARKLE_BIN='/path/to/Sparkle-2.10.1/bin'
export BAWAN_SPARKLE_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account bawan-updates -p)"
export NOTARY_PROFILE='existing notarytool profile'
```

Both apps must embed https://127.0.0.1:8443/appcast.xml as SUFeedURL and the same Sparkle public verification key. Keep each build's feed, archive prefix, and build number explicit in an isolated subshell.

Build the baseline first:

```sh
(
  set -eu
  export BAWAN_UPDATE_FEED_URL='https://127.0.0.1:8443/appcast.xml'
  export BAWAN_UPDATE_DOWNLOAD_URL_PREFIX='https://127.0.0.1:8443/baseline/'
  export BAWAN_BUILD_NUMBER='2.0.0'
  ./scripts/release.sh
)
```

It prepares build/release-artifacts/2.0.0-2.0.0/. Check the actual app metadata, signed appcast, enclosure, and checksum:

```sh
(
  set -eu
  APP='build/release/Bawan.app'
  OUT='build/release-artifacts/2.0.0-2.0.0'
  ARCHIVE='Bawan-2.0.0-macOS-arm64.zip'
  test "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist")" = 'https://127.0.0.1:8443/appcast.xml'
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = '2.0.0'
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" = '2.0.0'
  test "$(xmllint --xpath "string((//*[local-name()='enclosure']/@url)[1])" "$OUT/appcast.xml")" = 'https://127.0.0.1:8443/baseline/Bawan-2.0.0-macOS-arm64.zip'
  test "$(xmllint --xpath "string((//*[local-name()='enclosure']/@length)[1])" "$OUT/appcast.xml")" = "$(stat -f%z "$OUT/$ARCHIVE")"
  test "$(xmllint --xpath "boolean(//*[local-name()='enclosure'][@*[local-name()='edSignature']])" "$OUT/appcast.xml")" = true
  (cd "$OUT" && shasum -a 256 -c SHA256SUMS)
)
```

On the isolated cloud Mac, not Yu's Mac, install the signed, notarized baseline in /Applications, grant its shortcut permissions, and check both shortcuts from another app before the RC update.

Build the RC from the same frozen source:

```sh
(
  set -eu
  export BAWAN_UPDATE_FEED_URL='https://127.0.0.1:8443/appcast.xml'
  export BAWAN_UPDATE_DOWNLOAD_URL_PREFIX='https://127.0.0.1:8443/v2.0.0-rc.1/'
  export BAWAN_BUILD_NUMBER='2.0.1'
  ./scripts/release.sh
)
```

It prepares build/release-artifacts/2.0.0-2.0.1/. Check the actual app metadata, signed appcast, enclosure, and checksum:

```sh
(
  set -eu
  APP='build/release/Bawan.app'
  OUT='build/release-artifacts/2.0.0-2.0.1'
  ARCHIVE='Bawan-2.0.0-macOS-arm64.zip'
  test "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist")" = 'https://127.0.0.1:8443/appcast.xml'
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = '2.0.0'
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" = '2.0.1'
  test "$(xmllint --xpath "string((//*[local-name()='enclosure']/@url)[1])" "$OUT/appcast.xml")" = 'https://127.0.0.1:8443/v2.0.0-rc.1/Bawan-2.0.0-macOS-arm64.zip'
  test "$(xmllint --xpath "string((//*[local-name()='enclosure']/@length)[1])" "$OUT/appcast.xml")" = "$(stat -f%z "$OUT/$ARCHIVE")"
  test "$(xmllint --xpath "boolean(//*[local-name()='enclosure'][@*[local-name()='edSignature']])" "$OUT/appcast.xml")" = true
  (cd "$OUT" && shasum -a 256 -c SHA256SUMS)
)
```

The script creates the ZIP, signed appcast, and checksum locally; it does not upload them to GitHub or the test feed. Before testing, transfer the owner's unchanged RC ZIP, appcast, and checksums through a session-private attachment or other authorized private channel. Put them at the paths in the [loopback feed setup](test-feed.md) without modifying or regenerating the signature. Keep signing and notary credentials with the owner.

## Migration and acceptance gates

- For v1.0.0/v1.1.0 users, quit Bawan and manually replace the app in /Applications. Do not delete Application Support or user defaults. Retaining the existing model and settings is expected and must be verified.
- Moving from ad-hoc signing to Developer ID may require a one-time regrant of Input Monitoring and Accessibility. Manual translation does not need shortcut permission.
- On the isolated cloud Mac, not Yu's Mac, install the signed 2.0.0 baseline. Choose Check for Updates, download the RC until ready to install, start a real model-backed translation, then choose Install and Relaunch during the translation. Observe the complete final text; choose Copy and Restart and verify the full result was copied before restart. Verify installed short version/build 2.0.0/2.0.1.
- Verify settings/model retention without re-downloading the unchanged model. From another app, physically press Cmd+C twice and Option+T twice after the update without reauthorizing Input Monitoring or Accessibility. GUI-injected event delivery is not evidence of physical keyboard delivery or permission continuity; hosted unit-test notes alone do not prove physical testing impossible.
- Record the exact frozen source SHA, team/bundle identity, versions/builds, and both ZIP SHA-256 values. Require accepted notarization, a stapled valid ticket, Gatekeeper acceptance, and valid SHA256SUMS. Verify the RC enclosure URL, byte length, EdSignature, and version/build against the actual RC ZIP/app.
- The v2 stable feed is expected to return 404 before public publication. This is separate from the private loopback feed; the local appcast path also returns 404 until the owner's appcast is supplied. Public distribution and the stable feed remain blocked until the manager confirms all gates. The separate memory gate belongs to its assigned owner.

## Stable build after manager approval

Run this only after the manager confirms all release gates. All three release variables are explicit; the stable URLs cannot inherit the private loopback values from the RC shell:

```sh
(
  set -eu
  export BAWAN_UPDATE_FEED_URL='https://github.com/my-name-is-yu/Bawan/releases/latest/download/appcast.xml'
  export BAWAN_UPDATE_DOWNLOAD_URL_PREFIX='https://github.com/my-name-is-yu/Bawan/releases/download/v2.0.0/'
  export BAWAN_BUILD_NUMBER='2.0.2'
  ./scripts/release.sh
)
```

The output is build/release-artifacts/2.0.0-2.0.2/. After an approved build, verify the actual stable app and appcast:

```sh
(
  set -eu
  APP='build/release/Bawan.app'
  OUT='build/release-artifacts/2.0.0-2.0.2'
  ARCHIVE='Bawan-2.0.0-macOS-arm64.zip'
  test "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist")" = 'https://github.com/my-name-is-yu/Bawan/releases/latest/download/appcast.xml'
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = '2.0.0'
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" = '2.0.2'
  test "$(xmllint --xpath "string((//*[local-name()='enclosure']/@url)[1])" "$OUT/appcast.xml")" = 'https://github.com/my-name-is-yu/Bawan/releases/download/v2.0.0/Bawan-2.0.0-macOS-arm64.zip'
  test "$(xmllint --xpath "string((//*[local-name()='enclosure']/@length)[1])" "$OUT/appcast.xml")" = "$(stat -f%z "$OUT/$ARCHIVE")"
  test "$(xmllint --xpath "boolean(//*[local-name()='enclosure'][@*[local-name()='edSignature']])" "$OUT/appcast.xml")" = true
  (cd "$OUT" && shasum -a 256 -c SHA256SUMS)
)
```

This command prepares local artifacts; publishing them is a separate approved action.
