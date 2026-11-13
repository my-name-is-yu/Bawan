# Implemented UI captures

These unmodified PNGs are AppKit content-view captures generated locally on
an Apple Silicon MacBook on 2026-11-13 from the Bawan working tree, using the
`BAWAN_BUILD_TESTS=ON` Release build and the `translation_panel` and
`settings_navigation` CTests. They are not captures from the earlier CI run.

| File | Local test output |
| --- | --- |
| `translation-light.png` | `build/panel-smoke/light.png` |
| `translation-dark.png` | `build/panel-smoke/dark.png` |
| `settings-light.png` | `build/settings-smoke/light.png` |
| `settings-dark.png` | `build/settings-smoke/dark.png` |

The translation captures include the shared hard shadows on Translate, Copy and
Swap. These are model-free smoke-test views, not full desktop screenshots; OS
titlebar overlays and native window buttons are outside the captures.

Settings captures show the same 720×500pt window after navigating from the
translator, with the Translator back action in the fixed header and the body
scrolling below it.

The captures include the compact shortcut headings and setup guidance, shared
paper scrolling, and the footer hint hidden after input. Long English/Japanese
scrolling, error reveal, keyboard focus and native help are exercised by the
same run; their additional PNGs remain in the linked CI artifact.

The pane heading bands, language badges and horizontal rules have been removed.
Both translation text panes now start 24pt below the masthead and gain 55.5pt
of reading height at the same window size.
