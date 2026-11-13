#!/usr/bin/env python3
"""Observe potentially relevant shared macOS services without changing them."""

import argparse
import ctypes
import json
import os
import subprocess
import time


class RUsageInfoV2(ctypes.Structure):
    # Public sys/resource.h layout. proc_pid_rusage writes directly to this buffer.
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64)
        for name in (
            "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups",
            "ri_pageins", "ri_wired_size", "ri_resident_size", "ri_phys_footprint",
            "ri_proc_start_abstime", "ri_proc_exit_abstime", "ri_child_user_time",
            "ri_child_system_time", "ri_child_pkg_idle_wkups", "ri_child_interrupt_wkups",
            "ri_child_pageins", "ri_child_elapsed_abstime", "ri_diskio_bytesread", "ri_diskio_byteswritten",
        )
    ]


LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
LIBPROC.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
LIBPROC.proc_pid_rusage.restype = ctypes.c_int


def footprint(pid):
    usage = RUsageInfoV2()
    ctypes.set_errno(0)
    result = LIBPROC.proc_pid_rusage(pid, 2, ctypes.byref(usage))
    if result != 0:
        error = ctypes.get_errno()
        return {"physical_footprint_bytes": None, "rusage_resident_bytes": None,
                "process_start_abstime": None, "rusage_status": "unavailable",
                "rusage_info_flavor": 2, "rusage_errno": error, "rusage_error": os.strerror(error)}
    return {"physical_footprint_bytes": usage.ri_phys_footprint,
            "rusage_resident_bytes": usage.ri_resident_size,
            "process_start_abstime": usage.ri_proc_start_abstime,
            "rusage_status": "available", "rusage_info_flavor": 2,
            "rusage_errno": None, "rusage_error": None}


def snapshot(extra_pids=()):
    output = subprocess.run(
        ["ps", "-axo", "pid=,rss=,comm="], check=True, capture_output=True, text=True
    ).stdout
    processes = []
    names = ("translation", "translate", "modelmanager", "intelligence", "anecompiler", "generative")
    for line in output.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3:
            continue
        pid = int(fields[0])
        if pid not in extra_pids and not any(name in fields[2].lower() for name in names):
            continue
        processes.append({"pid": pid, "rss_bytes": int(fields[1]) * 1024,
                          "command": fields[2], **footprint(pid)})
    return processes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    parser.add_argument("--seconds", type=float, default=30)
    parser.add_argument("--interval", type=float, default=0.5)
    parser.add_argument("--pid", type=int, action="append", default=[],
                        help="Also observe this PID, regardless of process name; repeatable")
    args = parser.parse_args()
    if args.seconds < 0 or args.interval <= 0:
        parser.error("seconds must be nonnegative and interval must be positive")
    start = time.monotonic()
    with open(args.output, "w", encoding="utf-8") as stream:
        while True:
            elapsed = time.monotonic() - start
            row = {"elapsed_ms": elapsed * 1000, "processes": snapshot(args.pid),
                   "note": "Shared-service process metrics; changes are not exclusively attributable to this app."}
            stream.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
            stream.flush()
            if elapsed >= args.seconds:
                break
            time.sleep(min(args.interval, max(0, args.seconds - elapsed)))


if __name__ == "__main__":
    main()
