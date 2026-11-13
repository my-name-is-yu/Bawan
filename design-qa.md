# Bawan Vintage UI QA — 2026-11-13

**Current result: Bawan v1 accepted for normal use on 2026-11-14.** Full-window, live appearance/accessibility and 20-cycle whole-app measurements were performed on 2026-11-13. The user confirmed both physical-key shortcuts, including selection translation without taking source-app focus. Advanced GPU/allocation tracing and sleep/wake recovery remain unverified; the original exhaustive checklist below is not fully passed. See [current local acceptance evidence](design/acceptance-2026-11-13.md) for results and limits.

## Visual Target

- **Reference:** `design/vintage-reference.png` (third refinement), updated to remove the `×` next to Settings, use native macOS window controls, add a matching dark theme and in-window Settings view, and drop the `ORIGINAL`/`TRANSLATION` bands, language badges, and horizontal rules (both panes start 24pt below the 80pt masthead, gaining 55.5pt of reading height).
- **Viewport:** 720×500pt initial, 640×420pt minimum (AppKit coordinates).
- **Light palette:** cream `#F7E7BB`, ink `#443024`, vermilion `#B53B28`, gold `#D99E3D`.
- **Dark palette:** espresso `#28211C`, ivory `#F5E6C8`, red-brown `#7B2D20`, gold `#C99B53`.

## Completed Checks

### Rename verification (local MacBook, 2026-11-13)
- Clean Release build (`BAWAN_BUILD_TESTS=ON`, `BAWAN_BUILD_SMOKE=ON`) succeeded; 9/9 CTests passed in 13.88s, and `codesign --verify --strict build/Bawan.app` passed.
- Bundle name, executable, and display name are `Bawan` (`local.bawan.Bawan`); packaged mascot, paper, and icon assets match existing artwork byte for byte.
- Regenerated light and dark translation and Settings captures in `design/screenshots/`, with local provenance documented alongside them.
- Removed the obsolete shortcut-setting fallback (verified by the preferences test) and all old product-name references in current source text and filenames; the local repository directory name and Git history are intentionally kept.
- Unregistered launch at login, quit the previous installed app, and removed the old bundle, preferences, model directory, and build outputs (macOS retains a disabled historical login-item record; custom untracked UI-validation scripts and previews from the old build directory were saved outside the checkout).
- *Scope note:* No model was downloaded, the app was not installed in `/Applications`, and real-model inference was not rerun. This check is separate from the broader historical UI status below.

### Expanded text-area verification
- [Native CI run 43360514233](https://github.com/my-name-is-yu/Bawan/actions/runs/43360514233) (commit `b9fb0569df8a855dca9c71c1668263dff6e0ec6c`) passed arm64 build and signature checks, 5/5 CTests, pointer feedback, and official-model translation.
- Light and minimum-size dark captures confirm both pane tops sit 24pt below the masthead. Deleted bands, rules, constraints, and display-only language state were removed rather than hidden, while smoke tests continue to cover direction, reverse translation, long-text scrolling, and accessible roles.

## Historical Evidence

The following checks come from earlier implementation, CI, and follow-up reviews. They do not substitute for current full-window or live-app verification.

### Static, asset, and Linux integration checks
- Verified PNG integrity, mascot alpha channel, identical UI resource packaging across the app and both smoke executables, and shared external-inline caches across screens.
- Confirmed native AppKit views, regular app activation (`NSApplicationActivationPolicyRegular`, no `LSUIElement`), and a normal window level (non-floating, full-screen auxiliary eligible, preserves source-app focus during selection translation).
- Static contrast calculations (compositing the paper texture's extrema at 3.5%; saved in `build/ui-validation/static-checks.json`) are at least 4.59:1 on the textured light header, 4.70:1 on primary buttons, and 4.5:1 for body, secondary text, and settings status colors.
- Libclang 18.1.1 parsed the UI sources, `AppDelegate`, and both smoke tests against the macOS 14.5 SDK (arm64 macOS 14) with zero errors (syntax/API check only; reports under `build/`).
- After rebasing onto configurable-shortcuts `main`, the portable CMake build, `git diff --check`, and 2/2 Linux CTests (`copy_gesture`, `shortcuts`) passed (without exercising AppKit).

### Native CI acceptance and follow-up reviews
- **Automated AppKit smoke coverage:** `panel_smoke` and `settings_smoke` exercise both themes, initial/minimum sizes, appearance repainting, layout bounds, wrapping, independent scrolling, EN/JA and forced reverse translation, streaming edits, `Esc`/`Command-W`/native close, Copy/Copied/reset, and Settings states. Baseline CI for commit `8e556e2` passed; follow-up runs and earlier consistency results are linked in [PR #5](https://github.com/my-name-is-yu/Bawan/pull/5) (`8e556e2` captures do not validate later follow-up changes).
- **Component consistency:** Unified the 80pt masthead (centered 72pt mascot, no wordmark; Settings label inset 24pt left, return button right), fixed darker vermilion pressed state, 3pt hard shadows on enabled Translate/Cancel, Copy, and Swap buttons, ICC-aware color sampling, and alignment-rectangle spacing checks.
- **Mascot & controls:** `mascot_smoke` verifies tilt/hop/shake click playback and cancellation (exit, navigation, close, Reduce Motion) using one 144px downsampled bitmap without polling timers. Key recorder and press-count controls share a 28pt face and 13pt type; `Command-Return` mirrors Translate/Cancel; status messages use semantic roles and explicit recording/paused/key-release-wait states.
- **Settings & usability:** Settings run as a retained view controller inside the shared panel (non-recording `Esc` and back return without clearing or cancelling; leaving Settings stops recording while keeping held-key release protection). Follow-ups added prefix-preserving streaming appends that auto-scroll only within one line of the end, on-demand permission help, product-driven error scroll-into-view, explicit initial focus, and shared paper-textured scroll gutters with no added timers or background observers.

## Original Acceptance Checklist

The checklist below predates the local acceptance run linked above. Full-window and whole-app CPU/memory evidence is now recorded there; its remaining items and limits still prevent an unrestricted pass of this original checklist. Historical build/CI evidence alone does not complete these checks.

1. **Native build, signature, and tests:**
   ```sh
   ./scripts/build.sh -DBAWAN_BUILD_TESTS=ON
   cmake --build build --target shortcut_tests shortcut_preferences_tests panel_smoke settings_smoke --parallel 3
   codesign --verify --strict build/Bawan.app
   ctest --test-dir build --output-on-failure
   ```
2. **Reference comparison:** Compare `build/panel-smoke/` and `build/settings-smoke/` captures against `design/vintage-reference.png` using matching sample text and viewport.
3. **Full-window visual QA:** Inspect a live window screenshot for native traffic-light spacing relative to the medallion, as well as window focus, drag, and close behavior.
4. **Live OS & app behavior:** Verify macOS Reduce Motion and Increase Contrast settings, selection translation without stealing focus from other apps, and both translation directions in the running app.

## Whole-App Resource Acceptance

Measure before and after on the same Mac, recording commits, hardware/RAM, macOS, Release configuration, model SHA256, fixed EN/JA input, direction, window size, theme, and identical sampling settings. Complete model setup first and run only one Bawan process. For a comparison with an older minimum height, use matching dimensions such as 720×640pt.

- Warm up both themes and major UI states, then complete one translation in each direction. Measure each theme separately.
- After the 60-second model-release deadline (for example, at 65 seconds), record CPU, RSS, and physical footprint with the panel both open and closed. Keep RSS and footprint separate. Use Metal System Trace to check for continuous idle GPU work.
- Record translation CPU time, average CPU (one core = 100%), peak RSS, and peak physical footprint with the same input and sampling settings in both versions.
- After warmup, run 20 cycles of open → translate → translate a longer cancellation input → cancel after streaming starts and before completion → close. Use the same fixed passage repeated 20 times for cancellation. At 0/5/10/20 cycles, let cancellation and the main run loop settle, then record resources in the same closed state.
- Compare Allocations generations and Memory Graph at those checkpoints: one reused panel, with no cycle-proportional growth in app-owned views, constraints, callbacks, notification registrations, or retained strings. Investigate retained owners before treating OS caches or memory high-water marks as leaks; record causes rather than imposing arbitrary MB/% thresholds.

Use external tools without adding product monitoring loops or logs. Save conditions, before/after values, findings, screenshots, and Instruments traces under a reviewable path such as `build/ui-validation/`. `engine_profile` excludes AppKit and uses two of its 20 translations for warmup; it does not replace these 20 post-warmup UI cycles. Linux RSS does not establish macOS physical footprint or whole-app resource use.
