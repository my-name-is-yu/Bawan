#!/usr/bin/env python3
"""Hide candidate identities and deduplicate identical translations for grading."""

import argparse
import json
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", type=Path, default=ROOT / "tests/fixtures/short_translation_cases.json")
    parser.add_argument("--split", required=True)
    parser.add_argument("--raw", type=Path, action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    cases = [c for c in json.loads(args.cases.read_text()) if c["split"] in args.split.split(",")]
    rows = [json.loads(line) for path in args.raw for line in path.read_text().splitlines() if line.strip()]
    rows = [r for r in rows if r.get("type", "result") == "result" and not r.get("warmup")]
    grouped = {}
    for row in rows:
        grouped.setdefault(row["id"], {}).setdefault(row["output"], set()).add(row["variant"])
    rng = random.Random(7351)
    blind, mapping = [], {}
    for case in cases:
        if case["id"] not in grouped:
            raise ValueError(f"No output for {case['id']}")
        pairs = list(grouped[case["id"]].items())
        rng.shuffle(pairs)
        outputs = []
        for i, (value, variants) in enumerate(pairs, 1):
            oid = f"{case['id']}-o{i}"
            outputs.append({"output_id": oid, "text": value})
            mapping[oid] = sorted(variants)
        blind.append({**case, "outputs": outputs})
    args.output.write_text(json.dumps(blind, ensure_ascii=False, indent=2) + "\n")
    args.output.with_name(args.output.stem + "_mapping.json").write_text(json.dumps(mapping, indent=2) + "\n")
    print(json.dumps({"cases": len(blind), "unique_outputs": len(mapping)}))


if __name__ == "__main__":
    main()
