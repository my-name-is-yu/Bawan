# Test coverage review

Reviewed on 2026-11-16 against `f09ee8b` (Bawan v1). The review uses observable
results, readable state, and effects at external boundaries as the test contract.
Production code and test registrations are unchanged.

## Suite decisions

| Existing tests | Decision | Behavior and evidence | Coverage after cleanup |
| --- | --- | --- | --- |
| `shortcut_tests.cpp` | Merge common cases; retain mode differences | README: double press within 400ms, release required, no repeats/intervening keys/app switches; passive copy reaches the source app. `048a938`, `9612858`. | `testDoublePress` runs timing, hold, interruption, application change, cancel/reset and recovery for both modes. `testModifierRelease` retains their different modifier-release rules; `testSinglePress` and `testBindings` retain single/disabled/invalid bindings. |
| `engine_event_mailbox_tests.cpp` | Rewrite weak assertions; delete fixture-only metric | `33dd407`: a stalled UI receives the latest complete snapshot, preserving request identity, direction and terminal/lifecycle order. | Compare the entire drained event sequence. Retain scheduling/rescheduling and 10,000 concurrent completions, each delivered once in order. |
| `short_input_tests.cpp` | Retain boundaries; delete private prompt-string comparisons | `c6ee8a2`: short English excludes a sixth word, unsupported scripts, numbers-only input and malformed text; punctuation/connectors must not conceal extra words. | All 39 count cases remain. Public-engine short translation regressions live in `engine_smoke`; exact prompt wording/serialization is a tuning choice. |
| `engine_smoke.cpp` | Retain; extend semantic regression | `c6ee8a2`: short words/invitations must keep their meaning. `1905a01`: automatic/forced direction. `9612858`: bounded prompt allocation, oversized paste rejection/recovery. `f134100`: lazy load, warm-up, idle reload and cancellation. | Real `TranslationEngine::translate`: `ephemeral`, added `You're welcome to join.`, idiom completion/direction, ordinary six-word input, both translation directions, context independence, invalid UTF-8, oversized inputs, recovery, sliding-window streaming, cancellation and idle reload. |
| `engine_lifecycle.cpp` | Retain | `f134100`, `65fbca4`: no work before first use, missing-model errors, independent prewarm failure, retry, cancelled prewarm leaves Loading, unused shutdown stays quiet. | Existing public callbacks/quiet checks remain. A translation failure and a prewarm failure have different owners, so neither is redundant. |
| `shortcut_preferences_tests.mm` | Retain | Persistence, restore, rejection without value/notification changes, atomic fallback for invalid saved settings, duplicate rejection and keyboard adapter flags. `028460a`: ignore another app's legacy preferences. | First launch and valid v1 load/save, invalid types/rows/versions/duplicates preserving the entire defaults domain, explicit edits after fallback, and Fn/Caps Lock boundary checks. Public defaults comparisons verify saved values. |
| `shortcut_monitor_tests.mm` | Add native command routing regression | Custom global bindings must preserve native editing/Close while Bawan owns keyboard input; Settings must pass new events through. | Production monitor event routing with real CGEvents and a visible key nonactivating panel, single/double custom bindings, held-key draining, Option-T inside the translator, and custom/passive bindings outside it. Hosted AppKit can reactivate the app, so inactive-app input is not dynamically established. No installed event tap or physical-key delivery is claimed. |
| `panel_smoke.mm` | Retain regressions; rewrite geometry expectations | `766a002`, `351138d`, `d7bafc5`: wrapping, final-line following and preserving reading position. `1905a01`: reverse direction. `41142ca`: normal window ordering. Accepted geometry is in `design-qa.md`. | Existing real controls, key events, clipboard, callbacks, scrolling and window-order checks remain. Source edits clear completed output, disable stale Copy/Swap, reset direction and preserve Undo/Redo. `CheckBounds` independently expects an 80pt header and 72pt mascot. |
| `settings_smoke.mm` | Merge refresh assertions into navigation; rewrite geometry | `048a938`, `8e42eff`: recording, release protection and permissions. `4c37cc4`: preserve Undo/Redo across navigation. `d7bafc5`: preserve position/reveal full errors. | Reopen Settings after an external permission change, refresh the fake monitor's cached availability, then assert visible ready labels/help state. Existing recording, failures, focus, Undo/Redo, scrolling, login actions and color-role checks remain. Independent geometry also pins 28pt controls/13pt type. |
| `progress_smoke.mm` | Add progress motion regression | Issue #50: respect Reduce Motion and stop invisible work without caller lifecycle management. | Real hosted windows and rendered presentation pixels cover motion during event tracking, static centered unknown progress, live display-option changes, hidden ancestors/reparenting, window detach/order/close/reopen, explicit stop, determinate switching and resize. Light/dark bitmap checks retain fill ratios, colors and 8pt geometry. Reduce Motion is substituted only in this test process; system preferences are untouched. |
| `mascot_smoke.mm` | Retain; mark motion checks for later rewrite | `41142ca` and `design-qa.md`: finite playback, interruption/reset, Reduce Motion, fixed hit area and bounded shared bitmap. | Existing coverage remains. Motion-name/private-layer assertions alone do not establish visible movement; replacing them requires real AppKit presentation/rendering checks. They were not deleted without that replacement. |
| `app_delegate_smoke.mm` | Retain; mark private-state checks for later rewrite | `f134100`: latest pending selection, close cancellation, cold/prewarm errors expose Retry and end busy state, stale events cannot overwrite model setup. | Existing actual delegate/error/menu scenarios remain. Real source edits cancel queued/active requests; late Text/Complete events cannot restore stale output or finish a newer request. Private generation/state assertions should eventually be replaced by stronger callback/UI observations on macOS. |
| `engine_profile.cpp` | Retain as a benchmark | `f134100` and whole-app resource acceptance in `design-qa.md`. | CPU/RSS/footprint and repeated translation/reload measurements serve a different purpose from functional smoke checks. Linux RSS does not establish macOS footprint or AppKit resource behavior. |

## Changes and successor checks

| Removed or changed check | Observable behavior to protect | Successor |
| --- | --- | --- |
| Separate active/passive copies of timing/interruption scenarios | Inclusive 400ms boundary, 401ms timeout, backwards time, release/repeat rules, fresh pairs after cancellation/app changes; correct event delivery | `shortcut_tests::testDoublePress`, executed for each mode. Modifier-release exceptions remain separate. |
| Mailbox length-only/partial event assertions | Correct latest text, metadata, independent requests and ordered terminal barriers | `engine_event_mailbox_tests::requireEvents` compares complete public events, including adjacent requests and a repeated request after a terminal barrier. |
| `oldBytes` arithmetic/log | No user behavior: it calculated hypothetical bytes from the fixture, not measured implementation memory | Delete the metric. The stalled-UI scenario still requires one exact latest snapshot after 4,096 pushes. |
| Exact `detail::translationPromptPrefix` strings, including ordinary/reverse/mixed controls | Users need correct translation and routing, not identical private prompt bytes | Keep all deterministic classifier exclusions/boundaries. `engine_smoke` checks short-word meaning, invitation meaning, completion, ordinary input and resolved directions through the public engine. No replacement promises identical prefix bytes. |
| Zero/exact-one calls to internal Settings/monitor `refresh`, plus test counters | Returning to Settings reflects newly granted external permissions and clears obsolete help/warnings | Existing ready-state scenario now navigates out/back. The fake monitor learns of the permission grant only when refreshed; visible labels are the assertion. Exact internal call counts are discarded. |
| UI expected dimensions derived from production style constants | The accepted visible geometry survives accidental style-constant changes | `panel_smoke::CheckBounds` and `settings_smoke::CheckBounds` use independent dimensions from `design-qa.md`. Shared semantic color-role assertions remain valid invariants. |

`592c9d6` already removed repeated UI lifecycle checks, and `9612858` already
migrated obsolete copy-gesture tests to the production state machine. They are
not reintroduced. Similar-looking UI operations are retained when they cover
different entry points, failure modes or regression histories.

## Running the checks

Portable Release build (CMake 3.24+, C++17; downloads the pinned llama.cpp):

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DBAWAN_BUILD_APP=OFF -DBAWAN_BUILD_TESTS=ON -DBAWAN_BUILD_SMOKE=ON
cmake --build build --parallel 3
ctest --test-dir build --output-on-failure
./build/engine_smoke /path/to/plamo-3-translate-0.8b-Q4_K_M.gguf
```

The model-backed smoke is a separate executable, not one of the CTests. Use the
official model revision `1cf96ae02133958a20074bfdfab76517bb737d00`, SHA256
`70891ec70dc7ab4205745a38307867c2881b99239f20327927633abfe4bc9ec6`.

`engine_lifecycle` also accepts that model path as an optional argument:

```sh
./build/engine_lifecycle /path/to/plamo-3-translate-0.8b-Q4_K_M.gguf
```

Its default CTest cases hold the worker at the public Loading callback to
overlap latest-wins translations, warm-up, release, cancellation and shutdown.
They compare complete callback sequences, including exactly-once request
terminals, cancellation recovery and silent shutdown. With a model path, two
cases queue release before or after the latest pending translation.
They require one reused load, the correct request ID and direction, one
Complete after each displaced request's Cancelled, and Idle only after
completion, promptly rather than after the 60-second idle timeout.

The default cases also capture stderr from standard and nonstandard callback
exceptions. They require the event kind, request ID and bounded, escaped error
detail, then retry and compare the entire event sequence to detect recursive or
duplicate delivery. Cold translation load failures must report both the global
error (ID 0) and that request's error; warm-up failures report only the global
error, with the original error details preserved. With a model path, a further
case rejects invalid UTF-8 with only a request error and successfully translates
the next request using the same loaded model.

The held-Loading shutdown case proves that shutdown waits for an executing
callback, then completes without delivering queued events after it resumes.
This is a join/lifetime guarantee, not a wall-clock shutdown bound: cancellation
is observed at model-load progress callbacks, between 128-token prompt batches
and between generated tokens. Backend initialization, model I/O/mapping,
tokenization, context allocation, an individual inference call, cleanup and
the callback itself still have to return. The production worker remains joined
so its engine and backend resources stay alive throughout that work.

On an Apple Silicon Mac, build the native suite instead:

```sh
./scripts/build.sh -DBAWAN_BUILD_TESTS=ON -DBAWAN_BUILD_SMOKE=ON
cmake --build build --parallel 3
ctest --test-dir build --output-on-failure
```

For the usual pre-push check, `./scripts/check.sh` configures `build-check/`
with every native test, fails on warnings in Bawan's own sources (not
llama.cpp), and runs CTest. `./scripts/check.sh --sanitize` repeats it under
AddressSanitizer and UndefinedBehaviorSanitizer in `build-check-sanitize/`.
To run it before every push, add a hook:

```sh
printf '#!/bin/sh\nexec ./scripts/check.sh\n' > .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

Run the model-backed command separately there as well. The native CTests cover
preferences, monitor routing, panel, Settings, mascot and app delegate in addition to the five
portable checks. CI was intentionally removed in `babb935`; native validation
must not be assumed to happen automatically after opening a PR.

## Issue #46: progress and UTF-8 regressions

`short_input_tests` defines a 1–5 word Latin-script heuristic, not a language
detector. It accepts ASCII and Latin-1 letters (excluding ×/÷), Latin Extended-A/B
and Latin Extended Additional. U+0300–036F accents may follow a Latin letter or
another attached accent. ASCII digits join words, but numbers alone do not qualify.
The letter ranges follow the Unicode charts for
[Latin-1](https://www.unicode.org/charts/PDF/U0080.pdf),
[Extended-A](https://www.unicode.org/charts/PDF/U0100.pdf),
[Extended-B](https://www.unicode.org/charts/PDF/U0180.pdf) and
[Extended Additional](https://www.unicode.org/charts/PDF/U1E00.pdf).

Printable ASCII, Unicode spaces, U+2010–2027/U+2030–205E typography, and the
explicit Latin-1/common symbol set in `ShortInput.h` separate words. Apostrophes
and hyphens join only adjacent alphanumerics; repeated connectors break words.
Thus `café-au-lait` counts as one, while bullets, quotes and multiplication signs
cannot conceal a sixth word. Japanese (including halfwidth kana and supplementary
kanji), other scripts, emoji, controls/format characters, detached accents and
invalid/incomplete UTF-8 return zero. All previous exclusions remain except the
intentional acceptance of accented Latin text and the expanded separator set.

`utf8_tests` exercises the production decoder and prefix used by TranslationEngine:
valid scalar boundaries, invalid leads/continuations, overlong encodings,
surrogates, out-of-range values, and impossible partial tails. Every byte cut of
mixed 1–4 byte text must end at the last complete scalar; resumed and single-byte
token streams must preserve the complete text and Japanese detection. Potentially
valid incomplete output waits for another token; incomplete input is rejected.
`engine_smoke` additionally checks accented short translations, public input
rejection without output, and recovery.

Native `model_setup_state`, `settings_navigation` and `onboarding` checks cover
known 0/fraction/1 progress, unknown engine loading as `std::nullopt`, and restored
progress after loading ends. These require macOS; a portable build cannot verify
the Objective-C++ signatures or the AppKit indicator behavior.

Verified for #46 on Linux x86_64/GCC 14.2: Release build with
`BAWAN_WARNINGS_AS_ERRORS=ON`, all five portable CTests, and the full real-model
`engine_smoke` passed using the pinned model/revision/SHA256 above. Accented cases
produced `カフェ` and `カフェで会いましょう。`. Direct builds of `short_input_tests`
(82 cases) and `utf8_tests` also passed ASan/UBSan. The new short-input tests fail
against unchanged main at `café`. Native build, model progress/Settings/onboarding
tests, AppKit rendering and Metal inference remain unverified on this host.

## Shared-control appearance regression (#42)

`panel_smoke` renders the real primary/secondary footer buttons in Aqua and
Dark Aqua, enabled and disabled, and checks that disabled clicks leave translation
and the clipboard unchanged. `settings_smoke` renders checked/unchecked shortcut
checkboxes, the login toggle in both states, and both recorder/press-count inputs.
The checks assert opaque enabled faces, 40% disabled face opacity, light/dark
input colors, appearance-callback repaint requests, and unchanged alignment rects.
Repaint checks drain and verify both view/layer dirty flags before the callback,
then require a new view or layer repaint request, including layer-backed controls.
Rendered custom focus masks retain the checkbox-only rounded box, capsule toggle,
and rounded input bounds, excluding labels and outer corners. Action-button focus
mask bounds and pixels are compared with an equivalent native `NSButton`; these
tests do not claim to verify OS focus-ring styling.
The native checkbox and toggle click paths also verify preference changes and
exactly one owner callback, alongside the existing recorder/popup action scenarios.
Control and focus-mask PNGs are saved under `panel-smoke/` and `settings-smoke/`.

After the native build above, run:

```sh
ctest --test-dir build-check --output-on-failure -R '^(translation_panel|settings_navigation)$'
```

These additions were inspected on Linux, where AppKit is unavailable; their
compilation, execution and rendered PNGs still require macOS verification.

## Verification for this review

Environment: Linux x86_64, GCC 14.2, Release, pinned llama.cpp `b12307`, verified
official model above. Original and rewritten shortcut/mailbox tests passed
direct builds. The final CMake build and all four portable CTests passed;
the original and final full model smoke both passed. The final smoke translated
the short cases as `儚い` and `ぜひご参加ください。`. Native AppKit executables
cannot run on this host; native test changes have only been inspected and checked with
`git diff --check`. Their runtime behavior, macOS rendering and Metal variation
remain unverified in this review.

Fault injection used isolated copies of production files, linked to the actual
tests/library. Each mutated implementation compiled before its test was run;
the working production sources were never modified.

| Injected defect | Test that fails | Observed result |
| --- | --- | --- |
| Reject exactly 400ms (`<= interval` to `< interval`) | `shortcut_tests`, shared timing table | Fails boundary assertion. |
| Keep the pending pair armed after held-key repeat | `shortcut_tests`, shared long-hold case | Fails fresh-pair assertion. |
| Consume passive Cmd-C events | `shortcut_tests`, active/passive delivery assertions | Fails passive event-delivery assertion. |
| Replace latest snapshot text with wrong content of the same length | `engine_event_mailbox_tests` | Old test passes; rewritten test fails. |
| Drop latest snapshot direction | `engine_event_mailbox_tests` | Old test passes; rewritten test fails. |
| Merge adjacent Text events from different requests | `engine_event_mailbox_tests` | Old test passes; rewritten test fails. |
| Drop Complete events | `engine_event_mailbox_tests` | Both old and retained checks fail. |
| Start model loading in the constructor | Retained `engine_lifecycle` | Fails no-work-before-use assertion. |
| Omit Cancelled after prewarm is cancelled during Loading | Retained `engine_lifecycle` | Fails waiting for terminal Cancelled at request 0. |
| Remove multiword translation context | `engine_smoke`, public invitation translation | Fails meaning assertion: returns `どういたしまして。` instead of welcoming participation. |
| Emit unresolved `Automatic` direction in output events | `engine_smoke`, completed translation | Fails resolved-direction assertion. |

A behavior-preserving reorder of the shortcut's internal delivery-state
assignments still passes the consolidated tests. Removing the single-word hint
in an isolated translation probe produced another acceptable answer (`一時的`);
that internal prompt change is not claimed as a detected behavioral regression.
These samples do not establish translation quality for all inputs or Metal
backends. No native fault-injection result is claimed.
