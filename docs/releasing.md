# Signing and releasing Bawan

Public releases use the same bundle identifier (`local.bawan.Bawan`) and Developer ID team across versions. This gives macOS a stable identity for the app's shortcut permissions. Ad-hoc builds identify one binary and can lose permission continuity after rebuilding.

The published v1.0.0 is ad-hoc signed and has no updater. Its users must manually install the first signed, updater-enabled release. That transition may require granting Input Monitoring and Accessibility again. Subsequent signed updates should preserve the grants; verify this with two real signed releases before promising it to users.

## Prepare the certificates and keys once

1. Use the Account Holder account for an active Apple Developer Program team. In **Xcode → Settings → Apple Accounts**, select that account and team, open **Manage Certificates…**, then choose **+ → Developer ID Application**. This is the certificate for a directly distributed `.app`. Keep using the same team for future releases.
2. Confirm that the certificate and its private key are installed on the release Mac:

   ```sh
   security find-identity -v -p codesigning
   ```

   The output must include `Developer ID Application: Your Name (TEAMID)`. An `Apple Distribution` or `Apple Development` identity is not the certificate for this release process. If Xcode cannot create the certificate, use Apple's [Developer ID certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) and create the certificate signing request on this Mac so it retains the matching private key.

3. Configure a notarization credential profile in the macOS Keychain. Run the interactive command, then follow its prompts for the Apple account, team and app-specific password:

   ```sh
   xcrun notarytool store-credentials Bawan-notary
   ```

   The release script uses the profile name, without putting the password in the repository or command arguments. See Apple's [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
4. Download the pinned Sparkle distribution specified in `cmake/BawanUpdates.cmake` from the [official Sparkle releases](https://github.com/sparkle-project/Sparkle/releases). From that distribution, generate the update signing key:

   ```sh
   ./bin/generate_keys --account bawan-updates
   ./bin/generate_keys --account bawan-updates -p
   ```

   Keep the printed public key for `BAWAN_SPARKLE_PUBLIC_KEY`. The private key remains in the login Keychain. This Sparkle key is separate from the Apple certificate; use the same account and key for future releases. Back up both signing identities securely, including their private keys, before changing Macs. Never put private keys in the repository or release assets.

## Prepare a release

Update the project version in `CMakeLists.txt` for each public release. `BAWAN_BUILD_NUMBER` can supply a separate, increasing `CFBundleVersion`; omit it to use the project version. A new build must compare newer than all previously shipped builds. Do not reuse a public version or GitHub release tag for different app binaries.

```sh
export BAWAN_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export BAWAN_SPARKLE_PUBLIC_KEY='PUBLIC_KEY_PRINTED_BY_GENERATE_KEYS'
export NOTARY_PROFILE='Bawan-notary'
./scripts/release.sh
```

The script builds in `build/release/`, verifies signatures, submits the app to Apple's notary service, staples and validates the ticket, checks Gatekeeper, and creates a Sparkle appcast containing signed update archives. It leaves the ZIP, `appcast.xml` and `SHA256SUMS` in `build/release-artifacts/<version>-<build>/`. It never installs the app or publishes a GitHub release. If the output directory already exists, it stops rather than overwriting reviewed artifacts.

The default update feed is `https://github.com/my-name-is-yu/Bawan/releases/latest/download/appcast.xml`. Set `BAWAN_UPDATE_FEED_URL` before building to use a separate HTTPS test feed. The generated appcast then looks for the ZIP alongside the feed. If the ZIP is hosted in a different directory, set `BAWAN_UPDATE_DOWNLOAD_URL_PREFIX` to that HTTPS directory URL, including its trailing slash. `BAWAN_SPARKLE_KEY_ACCOUNT` defaults to `bawan-updates`.

With the default feed, the appcast points to `https://github.com/my-name-is-yu/Bawan/releases/download/v<version>/Bawan-<version>-macOS-arm64.zip`. Upload the final ZIP, `appcast.xml`, and checksum as assets on the corresponding GitHub release when it is ready to publish. Keep `appcast.xml` attached to every subsequent latest release, because existing apps read that stable URL. This initial pipeline produces full updates for the current macOS 14+ / arm64 baseline. Before introducing different system requirements or update channels, retain the relevant older entries in the appcast so those users still receive a compatible release.

## Acceptance before publishing

- Install an older Developer ID signed, notarized build in `/Applications`. Grant its shortcut permissions and exercise both shortcuts from another app.
- Publish the new archive and appcast to a separate HTTPS test feed accessible to that older test build. Use **Check for Updates…** to install the new version. Confirm the app restarts, its version increases, and both shortcuts work without toggling or re-adding permissions.
- Repeat with background update checks enabled. Choose **Install and Relaunch** during a translation and verify **Copy and Restart** puts the final translation on the clipboard before updating. Confirm offline checks do not interrupt translation.
- Compare idle memory after model unloading, with updater support disabled and enabled under the same conditions. Also observe memory during checking, download and installation; update helpers should not become a permanent background service.
- Check that existing settings and the downloaded model survive the update. An app-only update should not download the unchanged model again.

The updater uses the native Sparkle framework. App signing and notarization add no application background service; update checks, download and installation have their own temporary resource cost. Measure those separately from normal idle memory. See the [Sparkle setup](https://sparkle-project.org/documentation/) and [publishing guide](https://sparkle-project.org/documentation/publishing/) for the archive and signature requirements.

Automatic checks are off initially. Users can enable daily checks in Settings or check manually. Users choose when to download and install. New checks wait while translating. If installation is requested during an active translation, Bawan waits for the final text and lets the user copy it before restart. The restart guard covers Sparkle's postponement callback and graceful termination through AppKit.
