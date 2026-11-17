# Setup consistency pass — 2026-11-17

Onboarding and Settings now share one row pattern (title over status, controls on the trailing side, hidden actions keep their slot) and one serif type scale (`BawanSetupTitleSize` 24, section 18, row 15, body 14, caption 13). The checkbox, the launch-at-login switch and the progress bars are drawn in Bawan's palette instead of the system accent. The shortcut names come from `ShortcutActionTitle` everywhere, including the status menu. Both pages show keys and press counts in the same 128/80pt fields. Model status, icon, color and action copy come from `BawanPresentModel`, and Model License is always a beveled button. Each page's footer primary action shows and responds to ⌘↵. The Settings footer note is centered. Checked in light, dark and minimum-size captures.

# Onboarding and Settings chrome update — 2026-11-17

The setup pages now reuse the translator's chrome from `src/BawanChrome.{h,mm}`: the 80pt masthead with the 72pt medallion and trailing icon slot, the 72pt footer with its divider, the beveled serif buttons, and serif labels throughout. Settings shows a filled gear that returns to the translator, plus a footer Done button. Onboarding moves Start translating and Model License into the footer and drops the hero mascot, because the masthead medallion now carries the brand. Tests assert the shared header and footer metrics. Captures in `build-check/{onboarding,settings}-smoke/` were checked at 720×500 and 640×420 in light and dark. The sections below describe the earlier slim-masthead pass and are superseded where they conflict.

# Onboarding and Settings implementation QA — 2026-11-17

final result: passed

## Scope and visual truth

Native AppKit implementation based on the selected third concept. The two screens are separate states of one retained translator window, without tabs or a sidebar.

- Selected reference: `design/onboarding-settings-reference.png` (exact copy of the selected generated result `exec-71f129ef-7b96-45db-af37-12128424c8cf.png`).
- Base: initially `d277cca2808b0f35e983d2bba08d17103b4217ac`, integrated with `32e812ac5fff4070bf9f2603235ad34148f8bd42` before final verification; branch `yu/redesign-onboarding-settings`.
- Review preview: [implemented native screens](design/onboarding-settings-implemented.png), captured from the AppKit smoke-test views.
- Native implementation captures: `build/onboarding-smoke/ready-light.png`, `build/settings-smoke/target-light.png`.
- Source board: 1942×809px. Source-window crops: onboarding `(31,79)-(955,775)`, settings `(987,79)-(1912,775)`; original logical size/density is unspecified by the generated mock.
- Native viewport: 720×500pt at 2× density (1440×1000px); minimum 640×420pt (1280×840px). CSS size/deviceScaleFactor do not apply to AppKit.
- Comparisons preserve aspect ratio: source crops fit within 720×540px; native content within 720×500px. The resulting 40px height difference is recorded rather than stretching either image. Native content captures omit OS-rendered traffic lights/window shadow, which remain actual AppKit window controls.
- Matched state: model Ready. Onboarding has two enabled shortcuts awaiting their respective permissions; Settings has selection translation awaiting Input Monitoring and the opening shortcut intentionally Off.

## Comparison history

1. Opened source and native together in `build/setup-design-qa/onboarding-comparison-1.png` and `settings-comparison-1.png`.
   - P2: onboarding hero, headings and rows were too small/dense, leaving substantially more unused lower space than the selected source. Increased hero 80→120pt with a correctly downsampled 240px bitmap, heading 24→28pt, row 52→64pt, spacing 8→10pt and Start 40→44pt; replaced white native readout keycaps and filled utility buttons with the shared warm input/button surfaces.
   - P2: card titles used smaller sans typography, and the unconditional Login Items link added an unnecessary normal-state row. Matched18pt serif card headings, increased body/status sizing, and limited that remediation link to approval/error states. Grouped model readiness/license with its title.
   - P2: unprepared-model onboarding had a small setup link competing with a disabled Start. Added a separate primary model-setup/retry action and explicit license/download-size explanation; Ready layout is unchanged by this extra state.
2. Recaptured and opened `build/setup-design-qa/onboarding-comparison-2.png` and `settings-comparison-2.png` together with source. Full-view hierarchy, required controls and reading order are retained. Focused evidence: `onboarding-detail-comparison.png`, `settings-detail-comparison.png`.
3. An independent visual reviewer found no remaining P0/P1/P2 issue. Minimum-size footer is intentionally below the fold in the scrollable document; the runtime test scrolls Start into view, asserts it is fully visible, and captures `build/onboarding-smoke/minimum-dark-scrolled.png`.

## Required fidelity surfaces

- **Fonts/typography:** existing Georgia/Hiragino serif headings and native system body/control fonts. Clear heading/control/status hierarchy and readable native 13–16pt body/control sizes. Native font rendering differs from the generated illustration; no missing or clipped labels in checked states.
- **Spacing/layout:** slim 52pt mastheads,40pt header mascot, two equal Settings cards, full-width onboarding rows, grouped status/actions, and one-column utility settings. Normal-size Start stays visible; smaller windows use vertical scrolling without horizontal overflow. Text/controls remain within their parent/document bounds.
- **Colors/tokens:** existing dynamic cream/brown/vermilion/gold light palette and espresso/ivory dark palette; semantic status roles remain distinct. Native checkbox accent follows the OS rather than forcing the generated blue.
- **Image quality:** original supplied dog/paper assets are reused, with ImageIO thumbnail decoding sized for the 120pt onboarding hero; the existing 72pt shared mascot cache is preserved. SF Symbols provide native icons. No replacement artwork or new image dependency.
- **Copy/content:** selected capability names, optional-shortcut explanation, Start action, model status/license and separate normal Settings are retained. First-run masthead says Bawan rather than the mock’s misleading Settings. Setup/error/progress states extend the Ready-only visual target without inventing success. Required permissions follow the actual configured shortcut.

## Interaction and regression verification

Native Release build succeeds; all 11 CTest cases pass in 15.59s. `codesign --verify --deep --strict build/Bawan.app` and `git diff --check` pass. UI clipboard interactions use an isolated pasteboard.

- First launch does not prepare/download the model before explicit license continuation. Declining leaves setup pending; accepted preparation can be resumed/retried.
- Ready completion and Escape work without optional permissions. Completion is persisted when leaving Ready; existing users skip the introductory page.
- A selection shortcut before any model preparation now retains the selection and returns to setup rather than entering an unstarted busy queue; regression covered.
- Settings and onboarding are separate pages in the same window. Translator text, output, selection, reading position and Undo/Redo survive transitions; translator-only commands stay inactive on auxiliary pages.
- Shortcut enabled preference, missing permission, monitor failure and availability remain separate. Existing recording, physical-release, conflict, native shortcut, source-edit and stale-event tests remain.
- Latest-main memory-pressure/context changes are retained. Startup uses `ModelStore.prepare` (validated-file cache); explicit retry uses `revalidate`. Fixture counters and the unchanged verification-stamp regression cover that distinction.
- Model phase/progress/error/ready presentation, nonfinite progress normalization, model/license callbacks, launch-at-login callback/approval/error recovery and repeated-error reveal are covered.
- Normal/minimum dimensions and both appearances are captured. Minimum-size Start is reachable by scrolling; actual permission grants, model download and real-model inference were not performed in this QA run. Browser console checks are inapplicable to the native implementation.

## Residual polish and limits

P3 only: native control metrics, OS accent, slightly different paper tone/texture and extra reset/help affordances differ from the generated mock. No installed application was replaced; the deliverable is the local built application. The source mock does not specify transient model/error states; those were validated by behavior and native captures.

## Implementation checklist

- [x] Separate first-run guidance from everyday Settings; no tabs/sidebar.
- [x] Keep optional permissions independent from manual use and persist only completed introduction.
- [x] Preserve model-license gating, failure/retry, translator state, native keys and recording lifecycle.
- [x] Compare full view and focused regions, address P2 findings, verify normal/minimum/light/dark.
- [x] Native build, all 11 tests, signature and whitespace checks pass.

---

## Historical UI QA retained below

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
