# v2.0.0-rc.1 release-candidate handoff

This is a handoff, not a built or signed candidate. No tag or release has been published.

## Source and versions

The requested frozen source base is `main` at `d642e399e422ba0fc7e11912f092db11fb6d7e69`. This handoff changes project metadata and documentation, so the release source will have a different commit. After the change is reviewed, check out the approved PR head and record its exact SHA with `git rev-parse HEAD`; review and re-freeze that SHA before either release build. Do not build from the base SHA or treat an earlier-commit result as candidate evidence.

The planned release label is `v2.0.0-rc.1`. The project short version is numeric `2.0.0`; `BAWAN_BUILD_NUMBER` remains generic and defaults to the project version when unset. Build the signed update baseline as short version/build `2.0.0/2.0.0`, then the RC as `2.0.0/2.0.1`. Both build numbers exceed the previously signed `1.1.904`. A later stable `2.0.0` release must explicitly use build `2.0.2` or greater. The CMake metadata change changes the app binary metadata; do not claim the candidate is identical to a memory-measured binary. Memory remains a separate owner’s gate.

## Owner-run signed build and test feed

The current cloud has zero valid code-signing identities, no configured notarization/Sparkle release credentials, and no signed `2.0.0` baseline artifact. Run the steps below only on an already-authorized signing environment that has the existing Developer ID private key, notary profile, and Sparkle key in its Keychain. Do not export keys, generate a replacement Sparkle key, or use Local Hands.

After the PR is reviewed, fill in the full SHA from the approved PR head, then run this block to fetch and compare `FETCH_HEAD` before checking out the frozen source. The block refuses a dirty checkout and stops if the fetched SHA does not match:

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

Use the existing Developer ID identity from `security find-identity -v -p codesigning`. From the pinned Sparkle 2.10.1 tools, retrieve only the existing Sparkle public key with `<SPARKLE_BIN>/generate_keys --account bawan-updates -p`; stop if the existing key is unavailable. Do not run key-generation mode. Set the existing identity, public key, and notary profile in the release environment; keep private keys in Keychain.

The owner must supply a trusted, non-public HTTPS test host. Point both builds at that separate test appcast, never the stable/default feed:

```sh
export BAWAN_SIGNING_IDENTITY='Developer ID Application: <existing identity>'
SPARKLE_BIN='<path-to-Sparkle-2.10.1>/bin'
export BAWAN_SPARKLE_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account bawan-updates -p)"
export NOTARY_PROFILE='<existing notarytool profile>'
export BAWAN_UPDATE_FEED_URL='https://<owner-supplied-test-host>/<test-path>/appcast.xml'
```

Build and preserve the baseline first, with no public feed publication:

```sh
unset BAWAN_UPDATE_DOWNLOAD_URL_PREFIX
export BAWAN_BUILD_NUMBER=2.0.0
./scripts/release.sh
```

It prepares `build/release-artifacts/2.0.0-2.0.0/`. Verify its checksum from that artifact directory:

```sh
(cd build/release-artifacts/2.0.0-2.0.0 && shasum -a 256 -c SHA256SUMS)
```

Install this signed, notarized ZIP in `/Applications`, grant its shortcut permissions, and exercise both shortcuts from another app before testing the RC.

Build the RC from the same frozen SHA. The download prefix must explicitly target the RC directory, not the stable release path:

```sh
export BAWAN_BUILD_NUMBER=2.0.1
export BAWAN_UPDATE_DOWNLOAD_URL_PREFIX='https://<owner-supplied-test-host>/v2.0.0-rc.1/'
./scripts/release.sh
```

It prepares `build/release-artifacts/2.0.0-2.0.1/`. Verify its checksum from that artifact directory:

```sh
(cd build/release-artifacts/2.0.0-2.0.1 && shasum -a 256 -c SHA256SUMS)
```

The script does not upload or publish. Its output directories are version/build-specific and it refuses to overwrite an existing one; retain both ZIPs. Before the update test, the owner may place the RC ZIP in the explicit prefix directory and its appcast at the test-feed URL on the owner-authorized private HTTPS host. This private test hosting is permitted to exercise the gates; public distribution and the stable feed remain blocked until the manager confirms all gates. Do not change or publish the stable feed.

## Migration and acceptance gates

- For v1.0.0/v1.1.0 users, quit Bawan and manually replace the app in `/Applications`; do not delete Application Support or user defaults. Retaining the downloaded model and settings is expected and must be verified. Manual translation needs no shortcut permission.
- The ad-hoc-to-Developer-ID transition may require a one-time regrant of Input Monitoring and Accessibility. A subsequent same-team, same-bundle signed update must prove both physical shortcuts still work from another app without reauthorization.
- Use a Developer ID-signed/notarized old/new pair from the same team and bundle ID. Install the `2.0.0` baseline. In it, choose **Check for Updates**, download the RC until it is ready to install, start a real model-backed translation, then choose **Install and Relaunch** during that translation. Record the exact frozen source SHA, both bundle versions/builds, and each ZIP’s SHA-256.
- Observe the complete final translation, choose **Copy and Restart**, and verify the full result was copied before the app restarts. Verify the installed short version/build is `2.0.0/2.0.1`.
- From another app, physically exercise `⌘C` (Cmd+C) twice and `⌥T` (Option+T) twice after update, without toggling or re-adding Input Monitoring or Accessibility. Verify settings/model retention without re-downloading the unchanged model. Simulated tests, ready indicators, and earlier-commit evidence are not candidate evidence.
- In each artifact directory, run `shasum -a 256 -c SHA256SUMS`. Verify the RC appcast enclosure length equals the RC ZIP byte length, its EdSignature validates, and its short version/build identify `2.0.0/2.0.1`. Require notarization acceptance, a stapled/valid ticket, and Gatekeeper acceptance. The separate memory gate belongs to its assigned owner.
