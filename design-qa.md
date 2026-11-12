# Native translation panel QA — 2026-11-12

final result: passed

## Visual target and evidence

- Source visual truth: `$CODEX_HOME/generated_images/01a1cedc-dd26-73b3-8de6-bcafbc631368/exec-e8b3261e-3b34-4dd4-a451-7b44003dc114.png`, the selected Image Gen revision based on the user's sketch.
- Implementation: `build/panel-smoke/light.png`; supplemental states: `dark.png`, `minimum-permission-error.png`, `model-setup.png`, `copied.png` in the same directory.
- Native viewport: 720×500pt, minimum 640×420pt. Source pixels: 1505×1045; implementation pixels: 720×500 at 1× density. No browser or CSS viewport applies.
- Normalization: source downsampled to 720×500 with Lanczos; native capture unchanged. Transparent outer pixels composited on white for comparison only.
- Matched state: light appearance, fixed Japanese source and English result from the selected image, translation idle, shortcut available, no conditional messages, copy unconfirmed.
- Full-view comparison: `build/design-qa/reference-and-native.png` (source left, implementation right), opened and inspected together.
- Focused swap comparison: `build/design-qa/swap-detail.png` (source left, implementation right), both regions enlarged equally for inspection.
- These AppKit content-view fixtures supply output directly. Real-model interaction checks below were performed separately in the actual app.

## Findings and comparison history

1. Initial native capture exposed a vertically enlarged swap button. A frame assertion confirmed 32×42pt instead of a square.
2. Corrected the custom button's frame/alignment-rect conversion to identity: the app draws its own bezel across the entire bounds and does not use native button ornament insets.
3. Rebuilt and recaptured. The square/gutter assertions pass at both viewport sizes; the combined full-view and focused comparisons show no remaining actionable P0/P1/P2 differences.

## Required fidelity surfaces

| Surface | Assessment |
| --- | --- |
| Fonts and typography | Native system fonts; equal 16pt body sizes, matching hierarchy and readable Japanese fallback. Fixture wrapping matches the selected sample. Raster antialiasing differences from Image Gen are expected. |
| Spacing and layout rhythm | Language row fully removed; text starts 24pt below the header divider. Equal panes, consistent insets, central square swap button and interrupted divider. Footer actions remain aligned beneath their panes. |
| Colors and tokens | Existing dynamic light/dark palette retained. The native swap button uses the same neutral button token as the footer instead of the generated image's slightly lighter face; intentional consistency with existing controls. |
| Image and icon quality | Existing native SF Symbols remain sharp; swap uses a system two-arrow symbol. Its arrow stacking differs from the generated illustration without changing meaning. No raster UI or generated assets are embedded in the app. |
| Copy and content | No JP/EN labels, direction caption or language selector. Sample text and action labels match; tooltip and accessibility names describe the swap action. Conditional permission/error messages remain available. |

## Functional verification

- Release arm64 app build, strict signature verification, and `ctest --test-dir build --output-on-failure` pass (2/2).
- Panel checks cover automatic new input, reverse/repeated swap, retained reverse direction on retranslation, mixed-script output, automatic reset after editing/selection, and disabled swap while busy/unavailable/empty.
- Twenty lifecycle cycles retain the same panel, 21 app views and 63 explicit constraints; existing pointer, keyboard, copy/reset and cleanup checks pass.
- Real-model `engine_smoke` passes both automatic directions, resolved direction metadata, UTF-8/input limits, streaming, cancellation and KV reset.
- Actual app: Japanese→English, two successive swaps, fresh English editing→Japanese, and Copy Translation→Copied verified through native UI interaction. App left running.

## Limits and follow-up

- Local OS Reduce Motion and Increase Contrast were both off; this is not verification of the actual Increase Contrast toggle or all accessibility settings.
- Whole-app CPU/memory comparison, Instruments retained-object measurements and comprehensive motion-under-load checks remain separate, as documented in the README.
- No unresolved implementation decision or P0/P1/P2 visual issue blocks this change.
