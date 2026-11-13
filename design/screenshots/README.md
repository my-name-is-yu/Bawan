# Implemented UI captures

These unmodified PNGs are AppKit content-view captures generated locally on an Apple Silicon MacBook on 2026-11-13 from the Bawan working tree, not from the earlier CI run. They were produced by running the `translation_panel` and `settings_navigation` CTests against a Release build with `BAWAN_BUILD_TESTS=ON`.

Because these are model-free smoke-test captures of the content view rather than full desktop screenshots, OS titlebar overlays and native window buttons are excluded.

## Capture mapping

| File | Local test output |
| --- | --- |
| `translation-light.png` | `build/panel-smoke/light.png` |
| `translation-dark.png` | `build/panel-smoke/dark.png` |
| `settings-light.png` | `build/settings-smoke/light.png` |
| `settings-dark.png` | `build/settings-smoke/dark.png` |

## What is shown

- **Translation view (720×500pt):** Shows shared hard shadows on Translate, Copy, and Swap, shared paper scrolling, and the footer hint hidden after input. Pane heading bands, language badges, and horizontal rules have been removed, so both translation text panes start 24pt below the masthead and gain 55.5pt of reading height at the same window size.
- **Settings view (720×500pt):** Captured after navigating from the translator, showing the Translator back action in the fixed header, a scrollable body below it, compact shortcut headings, and setup guidance.
- **Additional coverage:** The same test run also exercises long English/Japanese scrolling, error reveal, keyboard focus, and native help; the additional PNGs are not included here.
