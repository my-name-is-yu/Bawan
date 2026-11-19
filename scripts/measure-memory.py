#!/usr/bin/env python3
"""Drive the opt-in app probe and check macOS physical footprint and RSS."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parent.parent
MODEL = (Path.home() / "Library/Application Support/local.bawan.Bawan"
         / "plamo-3-translate-0.8b-Q4_K_M.gguf")


def physical_mib(summary):
    match = re.search(r"^Physical footprint:\s*([\d.]+)([KMGT]?)\s*$", summary, re.M)
    if not match:
        raise ValueError("vmmap did not report Physical footprint")
    return float(match[1]) * {"": 1 / 1048576, "K": 1 / 1024,
                              "M": 1, "G": 1024, "T": 1048576}[match[2]]


def over_budget(row, budget):
    return any(not math.isfinite(row[key]) or row[key] > budget[key]
               for key in ("footprint_mib", "rss_mib"))


def run(args):
    budgets = json.loads(args.budget.read_text())
    output = REPO / "build" / ("memory-" + time.strftime("%Y%m%d-%H%M%S"))
    output.mkdir()
    print("Artifacts:", output, flush=True)
    rows = {}
    with (output / "app.log").open("w") as log:
        app = subprocess.Popen([str(REPO / "build/Bawan.app/Contents/MacOS/Bawan")],
                               env={**os.environ, "BAWAN_MEMORY_PROBE": str(output)},
                               stdout=log, stderr=log)
        try:
            def wait_file(name, expected, timeout):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if app.poll() is not None:
                        raise RuntimeError("App exited; see app.log")
                    path = output / name
                    value = path.read_text() if path.exists() else ""
                    if value in expected:
                        return value
                    if value == "error":
                        raise RuntimeError("Probe reported error; see app.log")
                    time.sleep(0.2)
                raise TimeoutError("Timed out waiting for " + name + ": " + str(expected))

            def command(value):
                (output / "reply").unlink(missing_ok=True)
                pending = output / "pending"
                pending.write_text(value)
                pending.replace(output / "command")
                return wait_file("reply", {"ok", "ready", "waiting"}, 30)

            def measure(phase):
                summary = subprocess.check_output(
                    ["/usr/bin/vmmap", "--summary", str(app.pid)], text=True,
                    stderr=subprocess.STDOUT)
                (output / (phase + "-vmmap.txt")).write_text(summary)
                rss = subprocess.check_output(
                    ["/bin/ps", "-o", "rss=", "-p", str(app.pid)], text=True)
                rows[phase] = {"footprint_mib": physical_mib(summary),
                               "rss_mib": int(rss.strip()) / 1024}

            command("ping")
            time.sleep(5)
            measure("cold_idle")
            for page in ("translation", "settings", "setup"):
                command(page)
                time.sleep(2)
                command("close")
                time.sleep(2)
            measure("windows_closed")
            if MODEL.is_file() or args.download_model:
                command("prepare")
                deadline = time.monotonic() + 1800
                while command("model") != "ready":
                    if time.monotonic() > deadline:
                        raise TimeoutError("Model preparation exceeded 30 minutes")
                    time.sleep(1)
                command("translation")
                command("translate")
                wait_file("engine", {"complete"}, 300)
                # Keep the panel open: closing it explicitly cancels engine work.
                measure("warm_translation")
                wait_file("engine", {"idle"}, 90)
                time.sleep(5)
                measure("idle_unloaded")
            else:
                print("SKIP warm_translation, idle_unloaded: no model; use --download-model")
                if args.require_model:
                    raise RuntimeError("Model required but unavailable")
        finally:
            app.terminate()
            try:
                app.wait(timeout=15)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait()
    (output / "measurements.json").write_text(json.dumps(rows, indent=2) + "\n")
    print("Phase                  Footprint MiB    RSS MiB   Limits (footprint/RSS)  Result")
    failed = False
    for phase, row in rows.items():
        budget = budgets[phase]
        exceeded = over_budget(row, budget)
        failed |= exceeded
        print(f"{phase:22} {row['footprint_mib']:13.1f} {row['rss_mib']:10.1f}"
              f"   {budget['footprint_mib']:7.1f}/{budget['rss_mib']:<7.1f}"
              f"        {'FAIL' if exceeded else 'PASS'}")
    return 1 if failed else 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--budget", type=Path, default=REPO / "scripts/memory-budget.json")
    parser.add_argument("--download-model", action="store_true",
                        help="download the 573 MB model via ModelStore (accept its model terms)")
    parser.add_argument("--require-model", action="store_true",
                        help="fail rather than skip model-backed phases (recommended for regression checks)")
    try:
        sys.exit(run(parser.parse_args()))
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print("Memory probe failed:", error, file=sys.stderr)
        sys.exit(2)
