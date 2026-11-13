# Lore vintage UI QA — 2026-11-13

final result: blocked

## Selected visual target

- Reference: `design/vintage-reference.png`, the third displayed refinement selected by the user.
- Approved changes to the reference: remove the × beside Settings; show native macOS close/minimize/zoom controls; add a matching dark appearance and settings screen in the same window.
- Follow-up: remove the ORIGINAL/TRANSLATION bands, language badges and horizontal rules. Both text panes start 24pt below the masthead, gaining 55.5pt of reading height at the same window size.
- Implementation viewport: initial 720×500pt, minimum 640×420pt. AppKit content coordinates apply, not browser/CSS pixels.
- Light palette: cream #F7E7BB, ink #443024, vermilion #B53B28, gold #D99E3D.
- Dark palette: espresso #28211C, ivory #F5E6C8, red-brown #7B2D20, gold #C99B53.

## Completed evidence

- Inspected the actual selected image and generated mascot/paper resources.
- PNG integrity, real mascot alpha, resource names and CMake packaging were checked. Product and both command-line smoke executables receive the same UI resources.
- Shared external-inline caches keep one palette, one mascot and one paper image across both screens.
- Source/control inspection confirms native AppKit views, editable source, selectable output, independent scrolling, accessible source/translation labels, and one reused panel.
- The previous regular-app configuration was applied: no LSUIElement agent flag, NSApplicationActivationPolicyRegular at launch.
- Static color calculations include the actual paper asset's extrema composited at 3.5%. Minimum normal-text contrast is 4.59:1 on the textured light header; primary buttons exceed 4.70:1. Body, secondary text and settings status colors also exceed 4.5:1. Results are in `build/ui-validation/static-checks.json`.
- Libclang 18.1.1 parsed the integrated UI sources, AppDelegate and both smoke tests against actual macOS 14.5 SDK headers, targeting arm64 macOS 14. Both the product NSBundle loader and test-resource loader branches passed with zero errors. Warnings are limited to existing unused callback/main parameters. Reports are retained under `build/`. This is syntax/API checking, not native linking or execution.
- Rebased onto the configurable-shortcuts version of main, retaining both shortcut rows, key recording/release handling, panel recall/focus behavior and Command-Shift-C copying. Both screens use the shared 720×500pt panel and support its 640×420pt minimum.
- Portable CMake configuration and build succeeded after integration. Both copy_gesture and shortcuts CTests passed (2/2) on Linux. This does not exercise AppKit.
- `git diff --check` passes.

## Native automated acceptance checks

- Both themes, initial and minimum sizes, paper-background repainting after appearance changes, header and footer bounds, loaded images, wrapping and separate text scrolling.
- Both EN/JA translation directions, forced reverse translation, source editing during streaming, and reset for a new request.
- Copy/Copied/reset behavior, native close, Esc, Command-W and cancellation.
- Settings callbacks, permission/login states, long error scrolling, theme changes and navigation in the same native window.
- CI explicitly builds both panel_smoke and settings_smoke and retains their captures.

## Component consistency follow-up

- Primary pressed color is a fixed darker vermilion in both themes; bitmap-based tests require at least 4.5:1 text contrast.
- Translate/Cancel, Copy and Swap share the primary action's 3pt hard shadow while enabled, using each face's own rounded or cut-corner silhouette. Disabled actions have no shadow; settings inputs and icon-only buttons remain flat. Existing light/dark captures cover the enabled actions.
- Both mastheads share an 80pt height and centered 72pt mascot, with no wordmark. Settings places its label at the left with a 24pt inset and keeps the return action at the right.
- Key recorder and press-count controls retain AppKit tracking, menus and focus while sharing a 28pt face, 13pt type, warm background and dark border. Tests read the rendered face to detect native bezel overpainting.
- The gold swap button keeps its clipped corners. Reset and section icons share explicit Medium symbol sizing.
- Informational, warning and error messages receive explicit semantic roles. Recording, paused and key-release-wait states replace the misleading ready status while listening is suspended.
- Command-Return invokes the same primary action as clicking: translate while idle and cancel while busy. Tests require cancellation without starting a new translation.
- Input faces and primary-button contrast are sampled using the capture's own ICC color space before converting to sRGB. AppKit's generic color wrapper must not reinterpret the raw display samples.
- Header spacing is measured with AppKit alignment rectangles, with raw bounds checked separately for clipping and overlap.
- Settings are a retained view controller inside the existing panel, with a fixed masthead and a vertically scrolling body. The back action and non-recording Esc restore the retained translation view without closing, clearing text or cancelling translation. Settings cannot undo hidden translator edits; a newly selected passage returns to the translator before clearing the previous editing session. Native close and Command-W close the shared window. Leaving settings ends recording while retaining held-key release protection.
- The original vintage implementation and earlier consistency results are available from [PR #5](https://github.com/my-name-is-yu/Lore/pull/5). Baseline captures for commit 8e556e2 were inspected during the consistency review; they do not validate later follow-up changes.

## Lightweight usability follow-up

- The initial footer hint is shown only before input/output and is hidden during translation.
- Prefix-preserving streaming updates append only the new tail to the existing text store. Output follows the end only when the reader is already within one line of it; native layout is resolved before following. Reading positions use document coordinates and temporary geometry, without retaining an old translation or adding scroll observers, timers or layout polling.
- Settings expose shortcut editing and press-count labels, show permission instructions only when needed, and move detailed guidance to an on-demand native help dialog. Input Monitoring and Accessibility remain optional for manual typing/pasting.
- Newly displayed settings errors are brought into view by the product, rather than by the smoke-test fixture. Settings entry has an explicit initial focus and keeps keyboard traversal inside the current screen.
- A shared native scroll configuration uses the paper palette and grain in Settings and both translation panes, including legacy scroller gutters.
- Existing views and image caches are reused. No background observer, timer or animation is added for this follow-up. Whole-app RAM/CPU measurements remain a separate manual check below.
- Copy Translation/Copied and copying partial output remain unchanged, as requested by the user.

## Blocking verification

This execution workspace is Linux. Native arm64 builds, signature validation and AppKit smoke checks run in macOS CI; the baseline run for commit 8e556e2 completed successfully, and follow-up runs are linked from PR #5. The AppKit content-view captures support component comparisons but omit native titlebar overlays and interactive operation in other apps. Full-window visual QA and real-app focus/permission/resource checks remain unverified, so the overall report stays blocked on those checks.

On an Apple Silicon Mac:

```sh
./scripts/build.sh -DLORE_BUILD_TESTS=ON
cmake --build build --target gesture_tests shortcut_tests shortcut_preferences_tests panel_smoke settings_smoke --parallel 3
codesign --verify --strict build/Lore.app
ctest --test-dir build --output-on-failure
```

Compare native captures in `build/panel-smoke/` and `build/settings-smoke/` with the selected reference using the same sample text and viewport. Content-view captures omit OS titlebar overlays: inspect a real window screenshot for the traffic lights, their spacing from the medallion, and native focus/drag/close behavior. Check the actual OS Reduce Motion and Increase Contrast settings, selection translation without taking focus, and both language directions in the running app.

Do not change this report to passed until the native build, tests, full-window review and reference comparison pass. Whole-app resource measurements remain separately documented in README.

## Expanded text-area verification

- [Native CI run 43360514233](https://github.com/my-name-is-yu/Lore/actions/runs/43360514233) for implementation commit `b9fb0569df8a855dca9c71c1668263dff6e0ec6c` passed arm64 build/signature checks, all five CTests, pointer feedback and official-model translation.
- Inspected the new light and minimum-size dark captures. Both pane tops are 24pt below the masthead, and native smoke tests retain direction, reverse-translation, long-text scrolling and accessible source/translation roles.
- The deleted bands and rules, their constraints and display-only language state are removed rather than hidden.
