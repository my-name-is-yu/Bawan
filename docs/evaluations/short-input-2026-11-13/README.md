# Saved short-input experiment

See [the result and limitations](../../short-input-evaluation.md),
[fixed input cases](../../../tests/fixtures/short_translation_cases.json),
[protocol](../../../tests/fixtures/short_translation_protocol.json), and
[candidate definitions](../../../tools/translation-eval/candidates.json).

- `selection.json` freezes the complete policy before confirmation generation.
- `development-*` and `confirmation-*` contain anonymous output, identity keys,
  AI scores, summary totals and the development grading disagreement.
- `raw-quality.json.gz` preserves all quality-run output, including the 16 PLaMo
  candidates, two Apple strategies, confirmation, controls and production parity.
  It is a JSON object keyed by run name; each entry contains `rows` and the PLaMo
  runner's manifest when applicable.
- `raw-performance.json.gz` preserves repeated PLaMo timing/memory output and
  Apple's request and OS-service samples. `performance.json` summarizes them.
- `apple-availability.json` records the OS-managed installation transition.
- `environment.json` records machine/model/build provenance.
  `production-verification.json` records local checks and real-app observations.
- `sha256sums.json` checks the saved artifacts. Repository/home prefixes in
  published process metadata are normalized to `$REPO`/`$HOME`.

Recompute the adoption decision using the saved blind grades:

```sh
python3 tools/translation-eval/summarize.py \
  --blind docs/evaluations/short-input-2026-11-13/confirmation-blind.json \
  --mapping docs/evaluations/short-input-2026-11-13/confirmation-mapping.json \
  --scores docs/evaluations/short-input-2026-11-13/confirmation-scores.json \
  --candidate single_en_multi_minimal_ja --output build/recomputed-adoption.json
```

To inspect or re-anonymize the original rows, extract any named run from
`raw-quality.json.gz` using Python's standard `gzip` and `json` modules, then
write its `rows` as JSONL. For example, the `heldout` and `control` entries are
inputs to `blind.py --split heldout,control`. The compressed performance archive
is also ordinary UTF-8 JSON and contains no executable or model weights.

The candidate was not tuned after confirmation. Repeated production inference
was a parity check against the fixed candidate, not another candidate search.
Scores remain subjective AI assessments; saved references are semantic guidance,
not exact-match translation strings.
