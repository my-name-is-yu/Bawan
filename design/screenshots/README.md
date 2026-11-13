# Implemented UI captures

These unmodified PNGs are AppKit content-view captures from the macOS CI run for
implementation commit `b9fb0569df8a855dca9c71c1668263dff6e0ec6c`:
[run 43360514233](https://github.com/my-name-is-yu/Lore/actions/runs/43360514233),
artifact `panel-view-captures` (ID `14006949909`).

| File | Artifact source |
| --- | --- |
| `translation-light.png` | `panel-smoke/light.png` |
| `translation-dark.png` | `panel-smoke/dark.png` |
| `settings-light.png` | `settings-smoke/light.png` |
| `settings-dark.png` | `settings-smoke/dark.png` |

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
