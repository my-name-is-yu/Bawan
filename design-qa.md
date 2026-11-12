# Lore vintage UI QA — 2026-11-12

final result: blocked

## Selected visual target

- Reference: `design/vintage-reference.png`, the third displayed refinement selected by the user.
- Approved changes to the reference: remove the × beside Settings; show native macOS close/minimize/zoom controls; add a matching dark appearance and settings window.
- Implementation viewport: initial 720×500pt, minimum 640×420pt. AppKit content coordinates apply, not browser/CSS pixels.
- Light palette: cream #F7E7BB, ink #443024, vermilion #B53B28, gold #D99E3D.
- Dark palette: espresso #28211C, ivory #F5E6C8, red-brown #7B2D20, gold #C99B53.

## Completed evidence

- Inspected the actual selected image and generated mascot/paper resources.
- PNG integrity, real mascot alpha, resource names and CMake packaging were checked. Product and both command-line smoke executables receive the same UI resources.
- Shared external-inline image caches keep one mascot and one paper image across both windows.
- Source/control inspection confirms native AppKit views, editable source, selectable output, independent scrolling, metadata-based language labels, and one reused panel.
- The previous regular-app configuration was applied: no LSUIElement agent flag, NSApplicationActivationPolicyRegular at launch.
- Static color calculations include the actual paper asset's extrema composited at 3.5%. Minimum normal-text contrast is 4.59:1 on the textured light header; primary buttons exceed 4.70:1. Body, language headings, secondary text and settings status colors also exceed 4.5:1. Results are in `build/ui-validation/static-checks.json`.
- Libclang 18.1.1 parsed the integrated UI sources and both smoke tests against actual macOS 14.5 SDK headers, targeting arm64 macOS 14. Both the product NSBundle loader and test-resource loader branches passed with zero errors. Warnings are limited to existing unused callback/main parameters. Reports: `build/native-syntax-check.json`, `build/native-product-syntax-check.json`. This is syntax/API checking, not native linking or execution.
- Rebased onto the configurable-shortcuts version of main, retaining both shortcut rows, key recording/release handling, panel recall/focus behavior and Command-Shift-C copying. Settings keep the 700pt width needed for the new controls.
- Portable CMake configuration and build succeeded after integration. Both copy_gesture and shortcuts CTests passed (2/2) on Linux. This does not exercise AppKit.
- `git diff --check` passes.

## Native tests prepared, not yet run

- Both themes, initial and minimum sizes, paper-background repainting after appearance changes, header and footer bounds, loaded images, wrapping and separate text scrolling.
- AUTO/— before direction resolution, both EN/JA directions, forced reverse translation, source editing during streaming, and reset for a new request.
- Copy/Copied/reset behavior, native close, Esc, Command-W, cancellation, and 20 reuse cycles without rebuilding app-owned views/constraints.
- Settings callbacks, permission/login states, long error auto-height, theme changes, and 20 reuse cycles.
- CI explicitly builds both panel_smoke and settings_smoke and retains their captures.

## Component consistency follow-up

- Primary pressed color is a fixed darker vermilion in both themes; bitmap-based tests require at least 4.5:1 text contrast.
- Both mastheads share 80pt height, 64pt mascot, 48pt wordmark, 80pt leading inset and 12pt brand gap. Settings place their subtitle beside the wordmark.
- Key recorder and press-count controls retain AppKit tracking, menus and focus while sharing a 28pt face, 13pt type, warm background and dark border. Tests read the rendered face to detect native bezel overpainting.
- Gold headings and the swap button share clipped corners. Reset and section icons share explicit Medium symbol sizing.
- Informational, warning and error messages receive explicit semantic roles. Recording, paused and key-release-wait states replace the misleading ready status while listening is suspended.
- Command-Return invokes the same primary action as clicking: translate while idle and cancel while busy. Tests require cancellation without starting a new translation.
- A fresh macOS CI run and capture review are required for these follow-up changes. Baseline CI captures for commit 8e556e2 were inspected during the consistency review; they do not validate this follow-up.

## Blocking verification

This execution environment is Linux. The native build script exits with the requirement for an Apple Silicon Mac. No macOS build, signature validation, native screenshot, real-app operation or reference-to-runtime visual comparison has been completed in this change. Previous native QA results belong to the earlier interface and do not validate this design.

On an Apple Silicon Mac:

```sh
./scripts/build.sh -DLORE_BUILD_TESTS=ON
cmake --build build --target gesture_tests shortcut_tests shortcut_preferences_tests panel_smoke settings_smoke --parallel 3
codesign --verify --strict build/Lore.app
ctest --test-dir build --output-on-failure
```

Compare native captures in `build/panel-smoke/` and `build/settings-smoke/` with the selected reference using the same sample text and viewport. Content-view captures omit OS titlebar overlays: inspect a real window screenshot for the traffic lights, their spacing from the medallion, and native focus/drag/close behavior. Check the actual OS Reduce Motion and Increase Contrast settings, selection translation without taking focus, and both language directions in the running app.

Do not change this report to passed until the native build, tests, full-window review and reference comparison pass. Whole-app resource measurements remain separately documented in README.
