# Implemented UI captures

These unmodified PNGs are AppKit content-view captures from the macOS CI run for
implementation commit `00da97ae1f1e3e916dcafc49ed8ebfab519af031`:
[run 43358055863](https://github.com/my-name-is-yu/Lore/actions/runs/43358055863),
artifact `panel-view-captures` (ID `14006458888`).

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
