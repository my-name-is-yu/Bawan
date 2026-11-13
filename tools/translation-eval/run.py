#!/usr/bin/env python3
"""Run recorded candidates through the shared engine; no third-party packages."""

import argparse
import hashlib
import json
import platform
import random
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODEL_SHA256 = "70891ec70dc7ab4205745a38307867c2881b99239f20327927633abfe4bc9ec6"


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, default=ROOT / "build/engine_evaluate")
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--cases", type=Path, default=ROOT / "tests/fixtures/short_translation_cases.json")
    parser.add_argument("--candidates", type=Path, default=Path(__file__).with_name("candidates.json"))
    parser.add_argument("--variants", default="")
    parser.add_argument("--split", choices=["dev", "heldout", "control"], default="dev")
    parser.add_argument("--selection", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--warmups", type=int, default=2)
    parser.add_argument("--seed", type=int, default=20261113)
    parser.add_argument("--production", action="store_true")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Output already exists; choose a new path to preserve the experiment record")
    if args.repeat < 1 or args.warmups < 0:
        parser.error("repeat must be positive and warmups nonnegative")
    if digest(args.model) != MODEL_SHA256:
        parser.error("The model does not match the pinned official Q4_K_M checksum")
    all_candidates = json.loads(args.candidates.read_text())
    requested = args.variants.split(",") if args.variants else [c["id"] for c in all_candidates]
    candidates = [c for c in all_candidates if c["id"] in requested]
    if set(requested) != {c["id"] for c in candidates}:
        parser.error("Unknown candidate")
    if args.split == "heldout":
        if not args.selection:
            parser.error("The heldout set requires a frozen --selection record")
        selection = json.loads(args.selection.read_text())
        if selection["cases_sha256"] != digest(args.cases):
            parser.error("Corpus changed after selection")
        if not set(requested) <= {"baseline", selection["selected"]}:
            parser.error("Only baseline and the fixed selection may use the heldout set")
    cases = [c for c in json.loads(args.cases.read_text()) if c["split"] == args.split]
    if not cases or not candidates:
        parser.error("No cases or candidates selected")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    manifest = {
        "cases_sha256": digest(args.cases), "candidates_sha256": digest(args.candidates),
        "model_sha256": MODEL_SHA256, "engine_sha256": digest(args.engine),
        "git_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "git_diff_sha256": hashlib.sha256(subprocess.check_output(["git", "diff", "HEAD"], cwd=ROOT)).hexdigest(),
        "platform": platform.platform(), "machine": platform.machine(),
        "llama_cpp_tag": "b12307", "sampler": "greedy", "context_tokens": 8192,
        "seed": args.seed, "split": args.split, "repeat": args.repeat,
        "variants": candidates, "production_build": args.production,
        "warmup_requests": args.warmups,
        "source_sha256": {str(p.relative_to(ROOT)): digest(p) for p in [
            ROOT / "src/TranslationEngine.cpp", ROOT / "src/TranslationPrompt.h", ROOT / "src/ShortInput.h",
            ROOT / "tests/engine_evaluate.cpp"]},
        "timing_note": "first_text_ms measures the first valid UTF-8 Text callback, not a model token",
    }
    args.output.with_suffix(".manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    rng = random.Random(args.seed)
    with args.output.with_suffix(".stderr.log").open("w") as log, args.output.open("w") as output:
        process = subprocess.Popen([str(args.engine), str(args.model)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=log, text=True, encoding="utf-8", bufsize=1)
        try:
            ready = json.loads(process.stdout.readline())
            if ready.get("type") != "ready":
                raise RuntimeError("Engine did not become ready")
            output.write(json.dumps(ready) + "\n")

            def request(case, variant, iteration, warmup=False):
                fields = [case["id"], variant["id"], "1" if variant.get("source_english") else "0",
                          variant.get("rule", "ordinary"), variant.get("context", "").encode().hex(),
                          variant.get("examples", "").encode().hex(), case["direction"], case["source"].encode().hex()]
                process.stdin.write("\t".join(fields) + "\n")
                process.stdin.flush()
                row = json.loads(process.stdout.readline())
                if row.get("id") != case["id"] or row.get("variant") != variant["id"]:
                    raise RuntimeError("Response did not match request")
                if not row.get("complete") or row.get("truncated"):
                    raise RuntimeError(f"Request failed: {row}")
                row.update(iteration=iteration, warmup=warmup)
                output.write(json.dumps(row, ensure_ascii=False) + "\n")
                output.flush()

            for i in range(args.warmups):
                request({"id": f"warmup_{i}", "source": "Please try again.", "direction": "en_to_ja"},
                        {"id": "baseline"}, i, warmup=True)
            for iteration in range(args.repeat):
                for case in cases:
                    order = candidates.copy()
                    rng.shuffle(order)
                    for variant in order:
                        request(case, variant, iteration)
            process.stdin.close()
            if process.wait(timeout=30):
                raise RuntimeError("Engine exited unsuccessfully")
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
    print(json.dumps({"output": str(args.output), "cases": len(cases), "variants": len(candidates),
                      "results": len(cases) * len(candidates) * args.repeat}))


if __name__ == "__main__":
    main()
