#!/usr/bin/env python3
"""Wait for macOS language installation, then evaluate only the dev split."""

import argparse
import json
import pathlib
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--status-log", required=True)
    parser.add_argument("--timeout-seconds", type=float, default=3600)
    parser.add_argument("--poll-seconds", type=float, default=30)
    args = parser.parse_args()
    if args.timeout_seconds < 0 or args.poll_seconds <= 0:
        parser.error("timeout must be nonnegative and poll interval must be positive")
    start = time.monotonic()
    while True:
        subprocess.run([args.host, "--status", "--append", "--output", args.status_log],
                       check=True, timeout=30)
        last = pathlib.Path(args.status_log).read_text(encoding="utf-8").splitlines()[-2:]
        statuses = {row["strategy_requested"]: row["status"] for row in map(json.loads, last)}
        print(json.dumps({"elapsed_seconds": round(time.monotonic() - start, 1),
                          "statuses": statuses}), flush=True)
        if statuses.get("lowLatency") == "installed":
            break
        if time.monotonic() - start >= args.timeout_seconds:
            raise SystemExit("Timed out waiting for OS-managed language installation; no evaluations run")
        time.sleep(min(args.poll_seconds, max(0, args.timeout_seconds - (time.monotonic() - start))))

    for strategy in ("lowLatency", "highFidelity"):
        command = [args.host, "--fixture", args.fixture, "--split", "dev",
                   "--strategy", strategy, "--output", args.output]
        if strategy == "highFidelity":
            command.append("--append")
        subprocess.run(command, check=True, timeout=600)
    rows = [json.loads(line) for line in pathlib.Path(args.output).read_text(encoding="utf-8").splitlines()]
    summary = {}
    for strategy in ("lowLatency", "highFidelity"):
        selected = [row for row in rows if row["variant"] == "apple_" + strategy]
        summary[strategy] = {"cases": len(selected),
                             "complete": sum(bool(row["complete"]) for row in selected)}
    print(json.dumps({"evaluation_complete": True, "summary": summary}), flush=True)


if __name__ == "__main__":
    main()
