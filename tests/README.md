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
| `shortcut_monitor_tests.mm` | Retain native command routing; add mode and release regressions (#39) | Custom global bindings preserve native editing/Close; Settings passes fresh input through. Reconfiguration and independent sleep/suspension/recording transitions cancel pending actions while correctly draining intercepted keys. | Production routing with real CGEvents, a key nonactivating panel, single/double active and passive bindings, held-key reconfiguration, stop/start and sleep/wake recovery, repeated triggers, and a fake SelectionReader that observes deferred copy without clipboard effects. Hosted AppKit can reactivate the app, so inactive-app input is not dynamically established. No installed event tap or physical-key delivery is claimed. |
| `selection_reader_tests.mm` | Retain selection acquisition behavior independently of event routing | Passive Cmd-C twice uses the first press's pasteboard baseline; active copy waits for release. Cancelled, replaced and reentrant sessions must not send copy events or deliver stale results. | Injected clipboard, copy, clock, foreground application and scheduled callbacks cover success, retry/timeout, access denial, empty/non-text input, copy failure, application changes, cancellation, replacement, reentrancy and recovery without event taps or system clipboard access. |
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

The selection acquisition tests also run independently of llama.cpp, event-tap
permissions, physical key delivery, visible windows and the system clipboard:

```sh
clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Isrc \
  tests/selection_reader_tests.mm src/SelectionReader.mm \
  -framework AppKit -framework CoreGraphics -o /tmp/bawan-selection-reader-tests
/tmp/bawan-selection-reader-tests
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

To isolate the first-run selected-text regression, run
`./build-check/app_delegate_smoke --first-run-selection`. It exercises the real
delegate and translator controls with isolated preferences, simulated model
readiness and controlled engine completion. It checks both readiness before
leaving onboarding and leaving onboarding before readiness. The default
`app_delegate_smoke` also includes this scenario.

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

## Component API regression (#43)

`panel_smoke` exercises the real footer-hint helper with asymmetric 48/96pt and
128/52pt neighbors, either neighbor missing, and both missing. At 720, 640 and
360pt widths, short, long and unbroken messages must remain centered in the
footer, fit inside it, and keep at least 12pt clear of each neighbor. Layout
checks use the label's alignment rectangle, allow AppKit's half-point centering
tie, and separately require its padded frame to fit inside the footer. The narrow
fixtures save `panel-smoke/footer-hint-*.png`. The panel's mascot lookup now uses
the `BawanMascotView` API rather than the removed image-view API.

`settings_smoke` cycles the real header button through primary, gold, secondary
and plain styles in Aqua and Dark Aqua. It checks tint priority, repainting,
normal/pressed/disabled face colors and opacity, and disabled navigation. An
explicit `contentTintColor`, including nil for AppKit's native tint, takes
priority over later style changes; a button without an override uses its style's
foreground. The 36pt button's face sample uses bitmap row 6, clear of the stroke
and centered gear. Captures are saved as `settings-smoke/action-*.png`.

`mascot_smoke` checks the view-only API, 72pt medallion and requested plain
intrinsic sizes, plain Auto Layout sizing, decorative accessibility and keyboard
behavior, fixed hit-test bounds during playback, and plain click/reset behavior
with the existing finite playback and Reduce Motion scenarios. The existing
motion-name checks are unchanged; their replacement belongs to #45.

On an Apple Silicon Mac, run the full native build and the three focused smokes:

```sh
./scripts/check.sh
ctest --test-dir build-check --output-on-failure \
  -R '^(translation_panel|settings_navigation|mascot_hover)$'
```

Inspect the new footer and style PNGs, and repeat `panel_smoke` / `mascot_smoke`
with OS Reduce Motion enabled (`BAWAN_EXPECT_REDUCE_MOTION=1`). Linux cloud ran
`PATH=/tmp/bawan-43-python/cmake/data/bin:$PATH ./scripts/check.sh -DBAWAN_BUILD_APP=OFF`
with CMake 3.31.10 and GCC 14.2.0: Release warnings-as-errors build and all four
portable CTests passed. AppKit is unavailable on that host, so no native compile,
smoke execution, PNG inspection, or failing-before/passing-after result is
claimed for these new regressions. There is no GitHub Actions workflow in this
repository to supply those missing native results automatically.

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

## Shortcut monitor state refactor (#39)

`ShortcutMonitorState` classifies stopped, asleep, suspended, configuration and
running modes while retaining suspension and configuration independently across
sleep and stop/start. Configuration bypasses actions but keeps permission/tap
availability observable. `ShortcutKeyOwnership` drains captured repeats/releases
across gesture reconfiguration and owns the deferred active-copy release.

`shortcut_tests` exercises those portable policies alongside the existing
active/passive gesture timing tests. `shortcut_monitor_tests` routes real CGEvents
through the production monitor and observes panel dispatch and SelectionReader
begin/read/cancel calls. It covers key/press-count/enable changes while held,
active/passive transitions, overlapping sleep/suspension/configuration, queued
cancellation, matching/duplicate releases and multiple fresh trigger cycles.

Verification on 2026-11-17: Linux x86_64, GCC 14.2. The warnings-as-errors
`./scripts/check.sh -DBAWAN_BUILD_APP=OFF` build and all four portable CTests passed.
A direct `shortcut_tests` build also passed AddressSanitizer and
UndefinedBehaviorSanitizer. In isolated header copies, each of three compiled
mutations failed the added tests: allowing actions during configuration,
forgetting to drain held keys after reconfiguration, and retaining a cancelled
copy release. `git diff --check` passed.

The native suite has **not been compiled or run** for #39: this cloud host lacks
Apple SDKs and AppKit. On macOS, run `./scripts/check.sh`, then
`./scripts/check.sh --sanitize`. The native monitor test itself can be built
without llama.cpp:

```sh
clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Isrc \
  tests/shortcut_monitor_tests.mm src/ShortcutBinding.cpp \
  src/ShortcutPreferences.mm src/ShortcutMonitor.mm src/SelectionReader.mm \
  -framework AppKit -framework CoreGraphics -framework ApplicationServices \
  -framework Carbon -o /tmp/bawan-shortcut-monitor-tests
/tmp/bawan-shortcut-monitor-tests
```

Even a successful native routing test does not establish installed event-tap,
physical-key, permission-prompt or actual system sleep/wake behavior; those
require a Mac session. No native or model-backed smoke success is claimed here.
