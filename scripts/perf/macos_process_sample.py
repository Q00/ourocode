#!/usr/bin/env python3
"""PID-scoped macOS process sampler for Ourocode performance runs.

The sampler is deliberately observational: it never sends signals, discovers
processes by name, or performs cleanup. Callers must pass every measured PID
with an explicit role. Output is newline-delimited JSON so an interrupted run
still leaves independently parseable records.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import math
import os
import platform
import re
import statistics
import sys
import time
import uuid
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from typing import IO, Any


SCHEMA = "ourocode.perf.process-sample.v1"
ROLE_PATTERN = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
PROC_PIDLISTFDS = 1
PROC_PIDTASKINFO = 4
RUSAGE_INFO_V2 = 2
MAX_PATH_BYTES = 4_096


class ProcTaskInfo(ctypes.Structure):
    _fields_ = [
        ("virtual_size", ctypes.c_uint64),
        ("resident_size", ctypes.c_uint64),
        ("total_user", ctypes.c_uint64),
        ("total_system", ctypes.c_uint64),
        ("threads_user", ctypes.c_uint64),
        ("threads_system", ctypes.c_uint64),
        ("policy", ctypes.c_int32),
        ("faults", ctypes.c_int32),
        ("pageins", ctypes.c_int32),
        ("cow_faults", ctypes.c_int32),
        ("messages_sent", ctypes.c_int32),
        ("messages_received", ctypes.c_int32),
        ("syscalls_mach", ctypes.c_int32),
        ("syscalls_unix", ctypes.c_int32),
        ("context_switches", ctypes.c_int32),
        ("thread_count", ctypes.c_int32),
        ("running_threads", ctypes.c_int32),
        ("priority", ctypes.c_int32),
    ]


class ProcFDInfo(ctypes.Structure):
    _fields_ = [("fd", ctypes.c_int32), ("fd_type", ctypes.c_uint32)]


class RUsageInfoV2(ctypes.Structure):
    _fields_ = [
        ("uuid", ctypes.c_uint8 * 16),
        ("user_time", ctypes.c_uint64),
        ("system_time", ctypes.c_uint64),
        ("package_idle_wakeups", ctypes.c_uint64),
        ("interrupt_wakeups", ctypes.c_uint64),
        ("pageins", ctypes.c_uint64),
        ("wired_size", ctypes.c_uint64),
        ("resident_size", ctypes.c_uint64),
        ("phys_footprint", ctypes.c_uint64),
        ("process_start_abstime", ctypes.c_uint64),
        ("process_exit_abstime", ctypes.c_uint64),
        ("child_user_time", ctypes.c_uint64),
        ("child_system_time", ctypes.c_uint64),
        ("child_package_idle_wakeups", ctypes.c_uint64),
        ("child_interrupt_wakeups", ctypes.c_uint64),
        ("child_pageins", ctypes.c_uint64),
        ("child_elapsed_abstime", ctypes.c_uint64),
        ("diskio_bytes_read", ctypes.c_uint64),
        ("diskio_bytes_written", ctypes.c_uint64),
    ]


@dataclass(frozen=True)
class Target:
    role: str
    pid: int
    executable_path: str
    executable_sha256: str
    process_start_abstime: int


class LibProc:
    def __init__(self) -> None:
        if platform.system() != "Darwin":
            raise RuntimeError("macos_process_sample.py requires macOS")
        self.library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.library.proc_pidinfo.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_uint64,
            ctypes.c_void_p,
            ctypes.c_int,
        ]
        self.library.proc_pidinfo.restype = ctypes.c_int
        self.library.proc_pid_rusage.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_void_p,
        ]
        self.library.proc_pid_rusage.restype = ctypes.c_int
        self.library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.library.proc_pidpath.restype = ctypes.c_int

    @staticmethod
    def _error(operation: str, pid: int) -> OSError:
        error_number = ctypes.get_errno()
        return OSError(error_number, f"{operation} failed for PID {pid}: {os.strerror(error_number)}")

    def rusage(self, pid: int) -> RUsageInfoV2:
        value = RUsageInfoV2()
        ctypes.set_errno(0)
        if self.library.proc_pid_rusage(pid, RUSAGE_INFO_V2, ctypes.byref(value)) != 0:
            raise self._error("proc_pid_rusage", pid)
        return value

    def task_info(self, pid: int) -> ProcTaskInfo:
        value = ProcTaskInfo()
        ctypes.set_errno(0)
        count = self.library.proc_pidinfo(
            pid,
            PROC_PIDTASKINFO,
            0,
            ctypes.byref(value),
            ctypes.sizeof(value),
        )
        if count != ctypes.sizeof(value):
            raise self._error("proc_pidinfo(PROC_PIDTASKINFO)", pid)
        return value

    def fd_count(self, pid: int) -> int:
        ctypes.set_errno(0)
        needed = self.library.proc_pidinfo(pid, PROC_PIDLISTFDS, 0, None, 0)
        if needed <= 0:
            raise self._error("proc_pidinfo(PROC_PIDLISTFDS size)", pid)
        entry_size = ctypes.sizeof(ProcFDInfo)
        capacity = needed + (32 * entry_size)
        buffer = ctypes.create_string_buffer(capacity)
        ctypes.set_errno(0)
        count = self.library.proc_pidinfo(
            pid,
            PROC_PIDLISTFDS,
            0,
            ctypes.byref(buffer),
            capacity,
        )
        if count < 0 or count % entry_size != 0:
            raise self._error("proc_pidinfo(PROC_PIDLISTFDS)", pid)
        return count // entry_size

    def executable_path(self, pid: int) -> str:
        buffer = ctypes.create_string_buffer(MAX_PATH_BYTES)
        ctypes.set_errno(0)
        count = self.library.proc_pidpath(pid, ctypes.byref(buffer), len(buffer))
        if count <= 0:
            raise self._error("proc_pidpath", pid)
        return os.fsdecode(buffer.value)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def positive_float(raw: str) -> float:
    value = float(raw)
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError("must be a finite number greater than zero")
    return value


def nonnegative_float(raw: str) -> float:
    value = float(raw)
    if not math.isfinite(value) or value < 0:
        raise argparse.ArgumentTypeError("must be a finite non-negative number")
    return value


def parse_target(raw: str) -> tuple[str, int]:
    role, separator, pid_text = raw.partition("=")
    if not separator or not ROLE_PATTERN.fullmatch(role):
        raise argparse.ArgumentTypeError("use ROLE=PID with a lowercase stable role")
    try:
        pid = int(pid_text, 10)
    except ValueError as error:
        raise argparse.ArgumentTypeError("PID must be a positive decimal integer") from error
    if pid <= 0:
        raise argparse.ArgumentTypeError("PID must be greater than zero")
    return role, pid


def percentile_nearest_rank(values: list[float], percentile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, math.ceil(percentile * len(ordered)) - 1)
    return ordered[index]


def open_output(path: str | None) -> tuple[IO[str], bool]:
    if path is None or path == "-":
        return sys.stdout, False
    return open(path, "x", encoding="utf-8", buffering=1), True


def emit(stream: IO[str], record: dict[str, Any]) -> None:
    stream.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
    stream.flush()


def collect_process(libproc: LibProc, target: Target) -> dict[str, Any]:
    usage = libproc.rusage(target.pid)
    if usage.process_start_abstime != target.process_start_abstime:
        raise RuntimeError(f"PID {target.pid} was reused during the run")
    task = libproc.task_info(target.pid)
    return {
        "role": target.role,
        "pid": target.pid,
        "process_start_abstime": usage.process_start_abstime,
        "user_cpu_ns": usage.user_time,
        "system_cpu_ns": usage.system_time,
        "phys_footprint_bytes": usage.phys_footprint,
        "resident_bytes": usage.resident_size,
        "wired_bytes": usage.wired_size,
        "pageins": usage.pageins,
        "package_idle_wakeups": usage.package_idle_wakeups,
        "interrupt_wakeups": usage.interrupt_wakeups,
        "virtual_bytes": task.virtual_size,
        "thread_count": task.thread_count,
        "running_threads": task.running_threads,
        "context_switches": task.context_switches,
        "fd_count": libproc.fd_count(target.pid),
    }


def add_interval_cpu(
    process: dict[str, Any],
    previous: dict[str, tuple[int, int, int]],
    monotonic_ns: int,
) -> None:
    role = process["role"]
    prior = previous.get(role)
    user = process["user_cpu_ns"]
    system = process["system_cpu_ns"]
    process["cpu_percent_interval"] = None
    if prior is not None:
        prior_monotonic, prior_user, prior_system = prior
        wall_delta = monotonic_ns - prior_monotonic
        cpu_delta = (user - prior_user) + (system - prior_system)
        if wall_delta > 0 and cpu_delta >= 0:
            process["cpu_percent_interval"] = (cpu_delta / wall_delta) * 100.0
    previous[role] = (monotonic_ns, user, system)


def summarize(samples: list[dict[str, Any]], targets: list[Target]) -> dict[str, Any]:
    roles: dict[str, Any] = {}
    for target in targets:
        processes = [
            process
            for sample in samples
            for process in sample["processes"]
            if process.get("role") == target.role and "error" not in process
        ]
        cpu = [
            float(process["cpu_percent_interval"])
            for process in processes
            if process.get("cpu_percent_interval") is not None
        ]
        footprints = [int(process["phys_footprint_bytes"]) for process in processes]
        threads = [int(process["thread_count"]) for process in processes]
        fds = [int(process["fd_count"]) for process in processes]
        roles[target.role] = {
            "successful_samples": len(processes),
            "cpu_percent_interval_mean": statistics.fmean(cpu) if cpu else None,
            "cpu_percent_interval_p95": percentile_nearest_rank(cpu, 0.95),
            "phys_footprint_bytes_median": statistics.median(footprints) if footprints else None,
            "phys_footprint_bytes_max": max(footprints) if footprints else None,
            "thread_count_min": min(threads) if threads else None,
            "thread_count_max": max(threads) if threads else None,
            "fd_count_min": min(fds) if fds else None,
            "fd_count_max": max(fds) if fds else None,
        }
    return roles


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", action="append", required=True, type=parse_target, metavar="ROLE=PID")
    parser.add_argument("--duration", type=nonnegative_float, default=30.0, help="sample window in seconds")
    parser.add_argument("--interval", type=positive_float, default=1.0, help="sample interval in seconds")
    parser.add_argument("--run-id", default=None, help="stable caller-provided run identifier")
    parser.add_argument("--phase", default="unspecified", help="stable phase label")
    parser.add_argument("--output", default="-", help="exclusive NDJSON output path, or - for stdout")
    parser.add_argument("--manifest", help="exclusive standalone manifest JSON path")
    args = parser.parse_args()

    if not ROLE_PATTERN.fullmatch(args.phase):
        parser.error("--phase must use lowercase letters, digits, underscore, or hyphen")
    roles = [role for role, _ in args.pid]
    if len(roles) != len(set(roles)):
        parser.error("every --pid role must be unique")
    pids = [pid for _, pid in args.pid]
    if len(pids) != len(set(pids)):
        parser.error("every measured PID must be unique")

    libproc = LibProc()
    targets: list[Target] = []
    for role, pid in args.pid:
        usage = libproc.rusage(pid)
        executable_path = libproc.executable_path(pid)
        targets.append(
            Target(
                role=role,
                pid=pid,
                executable_path=executable_path,
                executable_sha256=sha256_file(executable_path),
                process_start_abstime=usage.process_start_abstime,
            )
        )

    run_id = args.run_id or str(uuid.uuid4())
    manifest = {
        "schema": SCHEMA,
        "record": "manifest",
        "run_id": run_id,
        "phase": args.phase,
        "created_at_utc": utc_now(),
        "sampler_pid": os.getpid(),
        "duration_seconds": args.duration,
        "interval_seconds": args.interval,
        "clock": "time.monotonic_ns",
        "cpu_percent_semantics": "one fully occupied logical core equals 100 percent",
        "measurement_scope": "only the exact PIDs listed in targets; descendants are not implicit",
        "sampler_sha256": sha256_file(os.path.realpath(__file__)),
        "host": {
            "system": platform.system(),
            "release": platform.release(),
            "version": platform.mac_ver()[0],
            "machine": platform.machine(),
            "logical_cpu_count": os.cpu_count(),
            "page_size_bytes": os.sysconf("SC_PAGE_SIZE"),
        },
        "targets": [asdict(target) for target in targets],
    }

    stream, should_close = open_output(args.output)
    try:
        emit(stream, manifest)
        if args.manifest:
            with open(args.manifest, "x", encoding="utf-8") as manifest_stream:
                json.dump(manifest, manifest_stream, sort_keys=True, separators=(",", ":"))
                manifest_stream.write("\n")

        started = time.monotonic_ns()
        deadline = started + int(args.duration * 1_000_000_000)
        next_sample = started
        samples: list[dict[str, Any]] = []
        previous_cpu: dict[str, tuple[int, int, int]] = {}
        sample_index = 0
        had_error = False
        while True:
            now = time.monotonic_ns()
            record: dict[str, Any] = {
                "schema": SCHEMA,
                "record": "sample",
                "run_id": run_id,
                "phase": args.phase,
                "sample_index": sample_index,
                "captured_at_utc": utc_now(),
                "elapsed_ns": now - started,
                "processes": [],
            }
            for target in targets:
                try:
                    process = collect_process(libproc, target)
                    add_interval_cpu(process, previous_cpu, now)
                except (OSError, RuntimeError) as error:
                    process = {"role": target.role, "pid": target.pid, "error": str(error)}
                    had_error = True
                record["processes"].append(process)
            emit(stream, record)
            samples.append(record)
            sample_index += 1
            if now >= deadline:
                break
            next_sample = min(next_sample + int(args.interval * 1_000_000_000), deadline)
            remaining = next_sample - time.monotonic_ns()
            if remaining > 0:
                time.sleep(remaining / 1_000_000_000)

        emit(
            stream,
            {
                "schema": SCHEMA,
                "record": "summary",
                "run_id": run_id,
                "phase": args.phase,
                "completed_at_utc": utc_now(),
                "sample_count": len(samples),
                "status": "incomplete" if had_error else "complete",
                "roles": summarize(samples, targets),
            },
        )
    finally:
        if should_close:
            stream.close()
    return 1 if had_error else 0


if __name__ == "__main__":
    raise SystemExit(main())
