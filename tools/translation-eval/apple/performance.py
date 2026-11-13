#!/usr/bin/env python3
"""Measure Apple translation with the production PLaMo engine held resident."""

import argparse
import hashlib
import json
import math
import pathlib
import platform
import selectors
import statistics
import subprocess
import sys
import time

sys.dont_write_bytecode = True
from observe_services import snapshot


ROOT = pathlib.Path(__file__).resolve().parents[3]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def percentile95(values):
    return sorted(values)[math.ceil(len(values) * 0.95) - 1] if values else None


def summarize_memory(samples):
    processes = {}
    for sample in samples:
        for process in sample["processes"]:
            key = (process["pid"], process["process_start_abstime"])
            entry = processes.setdefault(key, {"pid": key[0], "process_start_abstime": key[1],
                "command": process["command"], "role": process["role"], "baseline": [], "run": [],
                "after": [], "unavailable_samples": 0})
            footprint = process["physical_footprint_bytes"]
            if footprint is None:
                entry["unavailable_samples"] += 1
            else:
                entry[sample["phase"]].append(footprint)
    result = []
    for entry in processes.values():
        baseline_samples = entry.pop("baseline")
        baseline = statistics.median(baseline_samples) if baseline_samples else None
        observed = entry.pop("run")
        after = entry.pop("after")
        peak = max(observed) if observed else None
        entry.update(baseline_median_footprint_bytes=baseline, peak_run_footprint_bytes=peak,
                     after_median_footprint_bytes=statistics.median(after) if after else None,
                     peak_increment_bytes=peak - baseline if peak is not None and baseline is not None else None,
                     newly_observed_without_baseline=baseline is None,
                     identity_confirmed=entry["process_start_abstime"] is not None)
        result.append(entry)
    return result


def ensure_no_other_benchmarks():
    output = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
    benchmark_names = {"AppleTranslationEval", "engine_evaluate", "engine_evaluate_production", "engine_profile"}
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and pathlib.Path(fields[1]).name in benchmark_names:
            raise RuntimeError(f"Another translation benchmark is running (PID {fields[0]}); wait for it to finish")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dev-fixture", type=pathlib.Path, required=True,
                        help="A dev-only array of exactly 60 cases; never supply the combined corpus")
    parser.add_argument("--model", type=pathlib.Path, required=True)
    parser.add_argument("--engine", type=pathlib.Path, default=ROOT / "build/engine_evaluate_production")
    parser.add_argument("--host", type=pathlib.Path,
                        default=ROOT / "build/apple-translation-eval/AppleTranslationEval.app/Contents/MacOS/AppleTranslationEval")
    parser.add_argument("--strategy", choices=["lowLatency", "highFidelity"], required=True)
    parser.add_argument("--output-dir", type=pathlib.Path, required=True)
    parser.add_argument("--repeat", type=int, default=5)
    parser.add_argument("--interval", type=float, default=0.2)
    args = parser.parse_args()
    if args.repeat < 2 or not 0.1 <= args.interval <= 0.5:
        parser.error("repeat must be at least 2 and interval between 0.1 and 0.5 seconds")
    cases = json.loads(args.dev_fixture.read_text(encoding="utf-8"))
    if len(cases) != 60 or any(case.get("split") != "dev" for case in cases):
        parser.error("The performance fixture must contain exactly 60 dev cases and no other split")
    ensure_no_other_benchmarks()
    availability = [json.loads(line) for line in subprocess.check_output(
        [str(args.host.resolve()), "--status"], text=True, timeout=30).splitlines()]
    if not any(row["strategy_requested"] == args.strategy and row["status"] == "installed"
               for row in availability):
        parser.error("The requested Apple strategy is not installed; no performance run started")
    provenance = {"dev_fixture_sha256": digest(args.dev_fixture), "model_sha256": digest(args.model),
                  "resident_engine_sha256": digest(args.engine), "apple_host_sha256": digest(args.host),
                  "platform": platform.platform(), "strategy_requested": args.strategy,
                  "repeat": args.repeat, "sampling_interval_seconds": args.interval,
                  "availability_before": availability}
    args.output_dir.mkdir(parents=True, exist_ok=False)
    manifest = args.output_dir / "manifest.json"
    manifest.write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
    repeated = [{"id": f"r{iteration:02d}:{case['id']}", "split": "dev",
                 "source": case["source"], "direction": case["direction"]}
                for iteration in range(args.repeat) for case in cases]
    fixture = args.output_dir / "dev-repeated.json"
    fixture.write_text(json.dumps(repeated, ensure_ascii=False) + "\n", encoding="utf-8")
    native_output = args.output_dir / "translations.jsonl"
    samples = []
    resident = None
    native = None
    start = time.monotonic()

    with (args.output_dir / "resident.stderr.log").open("w") as resident_error, \
         (args.output_dir / "apple.stderr.log").open("w") as native_error, \
         (args.output_dir / "services.jsonl").open("w", encoding="utf-8") as memory_log:
        def observe(phase):
            if resident is not None and resident.poll() is not None:
                raise RuntimeError("PLaMo resident engine exited before observations finished")
            pids = [process.pid for process in (resident, native) if process is not None]
            processes = snapshot(pids)
            for process in processes:
                process["role"] = ("plamo_resident" if resident and process["pid"] == resident.pid else
                                   "apple_host" if native and process["pid"] == native.pid else "shared_os_service")
            sample = {"elapsed_ms": (time.monotonic() - start) * 1000,
                      "phase": phase, "processes": processes}
            samples.append(sample)
            memory_log.write(json.dumps(sample, ensure_ascii=False) + "\n")
            memory_log.flush()

        def idle(phase):
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                observe(phase)
                time.sleep(args.interval)

        try:
            resident = subprocess.Popen([str(args.engine.resolve()), str(args.model.resolve())],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=resident_error,
                text=True, encoding="utf-8", bufsize=1)
            with selectors.DefaultSelector() as selector:
                selector.register(resident.stdout, selectors.EVENT_READ)
                if not selector.select(timeout=120):
                    raise RuntimeError("Resident PLaMo engine did not become ready within 120 seconds")
            ready = json.loads(resident.stdout.readline())
            if ready.get("type") != "ready":
                raise RuntimeError("Resident engine did not emit the expected ready record")
            provenance.update(resident_pid=resident.pid, resident_ready=ready)
            manifest.write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
            idle("baseline")
            command = [str(args.host.resolve()), "--fixture", str(fixture.resolve()), "--split", "dev",
                       "--strategy", args.strategy, "--output", str(native_output.resolve())]
            native = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=native_error)
            deadline = time.monotonic() + 900
            while native.poll() is None:
                observe("run")
                if time.monotonic() > deadline:
                    raise RuntimeError("Apple performance run exceeded 900 seconds")
                time.sleep(args.interval)
            if native.returncode:
                raise RuntimeError("Apple evaluation failed; inspect apple.stderr.log")
            idle("after")
        finally:
            if native is not None and native.poll() is None:
                native.terminate()
                native.wait(timeout=10)
            if resident is not None:
                if resident.stdin is not None:
                    resident.stdin.close()
                try:
                    resident.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    resident.terminate()
                    resident.wait(timeout=10)

    rows = [json.loads(line) for line in native_output.read_text(encoding="utf-8").splitlines()]
    warm = [row["completion_ms"] for row in rows
            if row["complete"] and not row["id"].startswith("r00:")]
    summary = {"provenance": provenance, "expected_requests": len(repeated), "observed_requests": len(rows),
               "all_requests_complete": len(rows) == len(repeated) and all(row["complete"] for row in rows),
               "first_request_completion_ms": rows[0]["completion_ms"] if rows else None,
               "warm_requests": len(warm), "warm_median_completion_ms": statistics.median(warm) if warm else None,
               "warm_p95_completion_ms": percentile95(warm), "p95_method": "nearest rank",
               "host_request_boundary_max_footprint_bytes": max((row[key] for row in rows
                   for key in ("before_physical_footprint_bytes", "after_physical_footprint_bytes")
                   if row[key] is not None), default=None),
               "per_process_memory": summarize_memory(samples),
               "notes": ["PLaMo is resident and idle; stdin stays open until observations finish.",
                         "The first pass is excluded from warm statistics; the first request is not a claim of cold OS models.",
                         "Host request memory is separate from sampled OS-service memory.",
                         "Per-process run peaks are sampled and may miss activity shorter than the interval.",
                         "No RSS is treated as physical footprint and no per-process peak sum is called system physical memory.",
                         "PID and process start time identify processes; unavailable samples and new processes are explicit."]}
    (args.output_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"summary": str(args.output_dir / "summary.json"), "complete": summary["all_requests_complete"]}))


if __name__ == "__main__":
    main()
