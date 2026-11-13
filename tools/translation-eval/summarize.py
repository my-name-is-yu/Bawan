#!/usr/bin/env python3
"""Reproduce quality totals and the predeclared adoption gate from saved scores."""

import argparse
import json
from collections import defaultdict
from pathlib import Path


def summarize(blind, mapping, scores):
    scores = {s["output_id"]: s for s in scores}
    outputs = {}
    totals = defaultdict(lambda: {"cases": 0, "correct": 0, "partial": 0, "wrong": 0, "score": 0, "groups": {}})
    for case in blind:
        for output in case["outputs"]:
            oid = output["output_id"]
            score = scores[oid]["score"]
            if type(score) is not int or not 0 <= score <= 2:
                raise ValueError(f"Invalid score for {oid}")
            for variant in mapping[oid]:
                key = (case["id"], variant)
                if key in outputs:
                    raise ValueError(f"Duplicate grade for {key}")
                outputs[key] = score
                t = totals[variant]
                t["cases"] += 1
                t["correct" if score == 2 else "partial" if score == 1 else "wrong"] += 1
                t["score"] += score
                group = t["groups"].setdefault(case["category"], {"cases": 0, "score": 0, "correct": 0, "wrong": 0})
                group["cases"] += 1
                group["score"] += score
                group["correct"] += score == 2
                group["wrong"] += score == 0
    if set(scores) != {o["output_id"] for c in blind for o in c["outputs"]}:
        raise ValueError("Grades do not exactly match anonymized outputs")
    return dict(totals), outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--blind", type=Path, required=True)
    parser.add_argument("--mapping", type=Path, required=True)
    parser.add_argument("--scores", type=Path, required=True)
    parser.add_argument("--candidate")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    blind = json.loads(args.blind.read_text())
    mapping = json.loads(args.mapping.read_text())
    scores = json.loads(args.scores.read_text())
    totals, outputs = summarize(blind, mapping, scores)
    report = {"totals": totals}
    if args.candidate:
        baseline, candidate = totals["baseline"], totals[args.candidate]
        if baseline["cases"] != len(blind) or candidate["cases"] != len(blind):
            raise ValueError("Incomplete baseline/candidate coverage")
        regressions = [{"id": c["id"], "baseline": outputs[c["id"], "baseline"],
                        "candidate": outputs[c["id"], args.candidate]} for c in blind
                       if outputs[c["id"], args.candidate] < outputs[c["id"], "baseline"]]
        group_gate = all(candidate["groups"][k]["score"] >= v["score"] for k, v in baseline["groups"].items())
        heldout = [c for c in blind if c["split"] == "heldout"]
        controls = [c for c in blind if c["split"] == "control"]
        if len(heldout) != 60 or len(controls) != 24:
            raise ValueError("An adoption decision requires all 60 heldout cases and 24 controls")
        for category in ("word", "idiom", "sentence"):
            if sum(c["category"] == category for c in heldout) != 20:
                raise ValueError("Heldout categories must contain 20 cases each")
        for category in ("long_en", "reverse_ja", "mixed_other"):
            if sum(c["category"] == category for c in controls) != 8:
                raise ValueError("Control categories must contain eight cases each")
        heldout_baseline = [outputs[c["id"], "baseline"] for c in heldout]
        heldout_candidate = [outputs[c["id"], args.candidate] for c in heldout]
        correct_delta = heldout_candidate.count(2) - heldout_baseline.count(2)
        report.update(candidate=args.candidate, regressions=regressions, gate={
            "heldout_correct_delta": correct_delta,
            "at_least_three_more_correct": correct_delta >= 3,
            "no_more_wrong": heldout_candidate.count(0) <= heldout_baseline.count(0),
            "no_correct_to_wrong": not any(r["baseline"] == 2 and r["candidate"] == 0 for r in regressions),
            "no_group_score_degradation": group_gate,
        })
        report["gate"]["passed"] = all(v for k, v in report["gate"].items() if k != "heldout_correct_delta")
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
