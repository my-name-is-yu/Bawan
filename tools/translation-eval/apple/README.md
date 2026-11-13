# Apple Translation evaluation host

Evaluation only. This signed Swift/AppKit/SwiftUI host uses public Translation APIs on
Apple Silicon with macOS 26.4 or later. It does not change Lore's production backend,
minimum OS version, settings, or model lifecycle.

## Build and install language data

From the repository root:

```sh
sh tools/translation-eval/apple/build.sh
build/apple-translation-eval/AppleTranslationEval.app/Contents/MacOS/AppleTranslationEval \
  --status --output build/apple-translation-eval/status-before.jsonl
build/apple-translation-eval/AppleTranslationEval.app/Contents/MacOS/AppleTranslationEval \
  --prepare --output build/apple-translation-eval/preparation.jsonl
```

The build script compiles and ad-hoc signs a dedicated evaluation app. `--prepare`
is the only mode that attaches a SwiftUI `translationTask` and calls
`prepareTranslation()`. Approve the OS's English/Japanese language download prompt.
The view records availability before and after. `prepareTranslation()` may return
after download approval while downloads continue; its successful return alone does
not prove the languages are installed. Wait for `--status` to report `installed`
before evaluation. Close this evaluation host using its button when finished.
Downloaded language data are managed by macOS and shared across apps.

## Evaluate an explicit split

The fixture is a JSON array containing `id`, `split`, `source`, and `direction`.
Other fields are ignored. `split` is `dev`, `heldout`, or `control`; `direction`
is `en_to_ja`, `ja_to_en`, or `auto`. Auto uses the same Japanese Unicode ranges
as Lore's current engine, not a probabilistic short-text language detector.

```sh
build/apple-translation-eval/AppleTranslationEval.app/Contents/MacOS/AppleTranslationEval \
  --fixture tests/fixtures/short_translation_cases.json --split dev \
  --strategy lowLatency --output build/short-translation-eval/apple_dev.jsonl
build/apple-translation-eval/AppleTranslationEval.app/Contents/MacOS/AppleTranslationEval \
  --fixture tests/fixtures/short_translation_cases.json --split dev \
  --strategy highFidelity --append --output build/short-translation-eval/apple_dev.jsonl
```

Normal evaluation checks availability and uses `init(installedSource:target:preferredStrategy:)`.
It never requests downloads. One request per case, sequentially, with sessions reused
per language direction. A missing pack or failed translation produces a row with
`complete=false` and an error. There is no PLaMo retry or second inference.
The framework returns a complete string, so `first_text_ms` is null and only
`completion_ms` is measured. The first case includes session/availability startup;
later cases reuse the session. Output files are replaced unless `--append` is present.

`strategy_requested` records the requested strategy, not an assertion about the
model actually selected by macOS. In particular, `highFidelity` can fall back to
traditional models when Apple Intelligence is unavailable. Do not label its results
as confirmed Apple Intelligence output without separate evidence.

Keep heldout cases sealed until the parent evaluation process selects a finalist.
This host does not score translations or choose a candidate.

For an already-approved OS download that is still in progress, the optional helper
polls availability (without requesting downloads), then runs both strategies on
dev only. It exits after an hour if installation remains incomplete:

```sh
python3 tools/translation-eval/apple/wait_and_evaluate.py \
  --host build/apple-translation-eval/AppleTranslationEval.app/Contents/MacOS/AppleTranslationEval \
  --fixture tests/fixtures/short_translation_cases.json \
  --output build/short-translation-eval/apple_dev.jsonl \
  --status-log build/apple-translation-eval/installation-status.jsonl
```

## Memory observation

Each translation records this host's before/after RSS and physical footprint in
bytes using Mach task info. This excludes allocations in Apple's separate services
and is not a sampled peak. Observe potentially relevant services separately:

```sh
python3 tools/translation-eval/apple/observe_services.py \
  --seconds 30 --interval 0.5 --output build/apple-translation-eval/service-memory.jsonl
```

The observer runs `ps` and public `proc_pid_rusage(pid, RUSAGE_INFO_V2, ...)` from
`libproc`. Its broad name filter includes the evaluation host and shared system
services; repeat `--pid PID` to include any additional specific process. It records
RSS from `ps`, and physical footprint, resident size, and process start time from
the public `rusage_info_v2` structure. All memory values are bytes. Permission
failure or a disappearing process produces null values with errno and an
`unavailable` status, never an estimate from RSS.

The ABI is specified in the macOS SDK's public `usr/include/libproc.h` and
`usr/include/sys/resource.h`. It neither stops nor configures any process.
Match both PID and process start time when calculating before/after increments;
report the host and services separately and flag new or missing processes.
Shared-service activity cannot be attributed exclusively to this app. Do not sum
RSS as physical memory or replace the final measurement with PLaMo resident.
Measurements collected while PLaMo evaluation runs concurrently are exploratory
quality-run telemetry, not latency or memory acceptance evidence.

## Performance with PLaMo resident

Run this only after quality selection, all other translation benchmarks have
finished, and the selected Apple strategy is installed. Supply a **dev-only** JSON
array of exactly 60 cases. The combined dev/heldout/control corpus is rejected.

```sh
python3 tools/translation-eval/apple/performance.py \
  --dev-fixture build/apple-translation-eval/dev-only.json \
  --model /absolute/path/to/the/verified/plamo.gguf \
  --strategy lowLatency \
  --output-dir build/apple-translation-eval/performance-lowLatency
```

The helper checks for existing benchmark processes before starting. Keep the
machine free of new translation benchmarks for the entire measurement. It starts
`build/engine_evaluate_production MODEL_PATH`, waits for its JSON `ready` record,
and keeps stdin open without sending translation requests. The model remains
resident until observations finish. It samples an idle three-second baseline,
then runs the dev cases five times in one Apple host process with reused sessions,
then samples three more idle seconds. Only its own child processes are closed at
the end; no system service or existing app is stopped.

The output directory must be new. It contains the dev-only repeated fixture with
`r00:`–`r04:` ID prefixes, provenance manifest, native JSONL, raw service samples,
stderr logs, and `summary.json`. Sampling defaults to 0.2 seconds (configurable
within 0.1–0.5 seconds). Summary timing includes the initial request and nearest-rank
p95/median of passes 2–5; pass 1 is excluded from warm statistics. The initial
request is a fresh-host measurement, not proof of cold OS model caches.

Memory is reported per process identity (PID plus start time), including the idle
PLaMo engine, Apple host, and shared services. Reported increments compare the
sampled run peak against that process's median idle baseline. Newly observed
processes have a peak but no invented baseline or delta. Unavailable samples and
unconfirmed identities are explicit. The host's own request-boundary memory is
reported separately. No RSS or sum of independently timed peaks is presented as
aggregate physical memory. Shared-service changes still require interpretation;
this helper does not decide the adoption gate.

## API references

- [TranslationSession](https://developer.apple.com/documentation/translation/translationsession)
- [Preparation and download consent](https://developer.apple.com/documentation/translation/translationsession/preparetranslation())
- [Installed-language initializer](https://developer.apple.com/documentation/translation/translationsession/init(installedsource:target:preferredstrategy:))
- [Translation strategies](https://developer.apple.com/documentation/translation/translationsession/strategy)
- [Language availability](https://developer.apple.com/documentation/translation/languageavailability/status)

The local macOS 26.4 SDK's Swift interfaces confirm the strategy APIs require 26.4+.
The SDK's Translation classes are not Sendable; `@preconcurrency import Translation`
is limited to this sequential evaluation host rather than adding unsafe conformance.
