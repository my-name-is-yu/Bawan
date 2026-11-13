# Short English translation evaluation

Developer tools, not runtime assets. Lore.app contains neither the candidate list
nor the evaluation switch. The C++ evaluator compiles the same engine source as
the app, changing only a private prompt hook. `engine_evaluate_production` links
the shipping engine to check output parity after adoption.

The fixed corpus and acceptance protocol are in `tests/fixtures/`. The corpus has
60 development cases, 60 confirmation cases and 24 controls. Only development
output may guide prompts or routing. Confirmation inputs are freshly authored for
this experiment; independence from every case in the unavailable earlier corpus
cannot be guaranteed. Grading is an AI semantic assessment, not a standardized
benchmark or a human translation study.

## Reproduce

Requires Apple Silicon, CMake, the C++ toolchain and Python 3.11+. Use the official
model already installed by Lore; the runner verifies the pinned SHA-256 before
loading it. No Python packages or additional PLaMo models are required.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DLORE_BUILD_TESTS=ON -DLORE_BUILD_SMOKE=ON
cmake --build build --target engine_evaluate engine_evaluate_production short_input_tests --parallel 3
python3 tools/translation-eval/run.py \
  --model "$HOME/Library/Application Support/local.lore.Lore/plamo-3-translate-0.8b-Q4_K_M.gguf" \
  --split dev --output build/new-dev.jsonl
python3 tools/translation-eval/blind.py --split dev \
  --raw build/new-dev.jsonl --output build/new-dev-blind.json
```

See [the Apple host instructions](apple/README.md) to prepare OS-managed language
data and evaluate Apple's two strategies. Pass each additional raw file to
`blind.py` using another `--raw` argument. The host is a separate signed evaluation
app and is never bundled with Lore.

Give only the blind file and the protocol to an evaluator. Save grades as an array
of `{output_id, score, reason}`. The generated `_mapping.json` contains identities
and must stay separate from the grading input. Preserve original grades and
document any adjudication; do not change grades to make an adoption gate pass.

```sh
python3 tools/translation-eval/summarize.py \
  --blind build/new-dev-blind.json --mapping build/new-dev-blind_mapping.json \
  --scores build/new-dev-scores.json --output build/new-dev-summary.json
```

Before confirmation, save a selection record containing at least `selected` and
`cases_sha256`, plus the rationale, exact prompt, classifier/routing and performance
evidence. `run.py --split heldout --selection RECORD` permits only baseline and
that selection. Use `--variants baseline,SELECTED_ID`; do not expose other
candidates to the confirmation set. Run controls separately and anonymize both
splits together for the adoption report. `summarize.py --candidate SELECTED_ID`
requires all 60 confirmation cases and checks the predeclared quality criteria.
If confirmation fails, preserve the evidence and reject the candidate.

## Timing and memory

The runner loads one engine and interleaves candidates for each input with a fixed
shuffle seed, clearing KV and resetting the greedy sampler on every request. It
records source/corpus/candidate/model/executable hashes and host information.
`--repeat 5` provides repeated development measurements; `--warmups 0` on separate
single-candidate runs measures the first request after load. Never tune from
confirmation performance repetitions.

`first_text_ms` is the first valid UTF-8 Text callback, not the first model token.
Apple returns complete strings and has no comparable streaming measurement. Use
completion time for cross-engine comparisons. Separate model load, first request
and warm median/p95 (nearest rank). Run acceptance measurements sequentially with
no other translation benchmark running.

RSS, physical footprint and lifetime maximum RSS are distinct measurements; do
not add them. Completion samples are not an observed peak during inference. Apple
service allocations are outside the host and must be measured separately, with
PLaMo still resident, before selecting an Apple route.
