#!/usr/bin/env python3
"""Repeatable whole-process performance benchmark for the wtop TUI.

Runs the real application in a pseudo-terminal and measures four numbers the
release goals reference: cold start to the first complete frame, steady-state
CPU over render windows, peak RSS, and page-switch input latency. The key
script and intervals are fixed so two runs on the same host compare directly;
absolute values still depend on the host's process count and hardware, so
cross-host comparisons are indicative only. The record samples process count
at each measurement phase, allowing a budget to reject workload drift.

Every result records *what was measured* and *on what*, because without that a
number is not a measurement of anything in particular.  This tool can drive two
different subjects -- the development tree, or a release bundle named by
WTOP_BENCH_EXECUTABLE -- and they are not the same program: measured on the same
host minutes apart, the bundle started 15% slower and held 25% more resident
memory than the source tree.  The two records had byte-identical key sets, so
nothing downstream could tell which one it was holding.  The subject and the
host are therefore part of the record, not decoration on it, and the banner's
"compare same host only" is only actionable if the host is written down.

Usage: tools/perf_benchmark.py [--profile NAME] [--json PATH]
       [--pages N] [--window-seconds N] [--startup-timeout SECONDS]
"""

# The annotations are spelled with typing.Optional/Tuple/Dict/List rather than
# `X | None` and `list[...]`.  The other two Python tools in this tree are
# written the same way, and for the same reason: the oldest image this project
# measures on -- manylinux2014, whose interpreter is 3.6 -- parses neither PEP
# 604 unions nor builtin generics, and a `from __future__ import annotations`
# header there is a SyntaxError.  This file's guard lives in the unit suite,
# which the cross-libc container runs, so a tool that cannot be imported there
# takes a test with it.

import argparse
import fcntl
import json
import math
import os
import pathlib
import pty
import select
import signal
import struct
import termios
import time
import typing

ROOT = pathlib.Path(__file__).resolve().parent.parent
LUA = os.environ.get("WTOP_LUA") or str(ROOT / ".tools/lua-5.5.1/bin/lua")
EXECUTABLE = os.environ.get("WTOP_BENCH_EXECUTABLE", "")
COLUMNS, ROWS = 120, 34
FRAME_END = b"\x1b[0m"

# These are page content, not tab names. Every frame's tab bar spells all tabs,
# so waiting for "Processes" after pressing 2 could time an unrelated repaint
# before the process page exists. The fixed 120x34 benchmark layout shows each
# of these fields even when the corresponding provider has no measurements.
PAGE_MARKERS = {
    1: b"Kernel", 2: b"Command",
    6: b"Network throughput", 7: b"GPU utilization",
}


def completed_frame_offset(output: bytearray, marker: bytes, start: int = 0) -> typing.Optional[int]:
    """End offset of the first encoded frame containing destination content."""
    position = output.find(marker, start)
    if position < 0:
        return None
    ending = output.find(FRAME_END, position + len(marker))
    return ending + len(FRAME_END) if ending >= 0 else None


def describe_subject() -> typing.Dict[str, object]:
    """What this run actually measured.

    Two subjects are supported and they are not interchangeable.  A bundle is
    the artifact a release ships: an executable with its modules bundled.
    The development tree is the same sources loaded from
    disk by the project's own interpreter with the freshly built native module
    on LUA_CPATH.  Measured on one host, the two differ well beyond noise, so a
    number without this field cannot be attributed to either.
    """
    if EXECUTABLE:
        path = pathlib.Path(EXECUTABLE)
        return {
            "kind": "bundle",
            "path": str(path),
            "resolved": str(path.resolve()) if path.exists() else "",
            "present": path.is_file() and os.access(str(path), os.X_OK),
        }
    source = ROOT / "src/wtop.lua"
    interpreter = pathlib.Path(LUA)
    module = ROOT / "build/native/wtop_native.so"
    missing = []
    if not source.is_file():
        missing.append(str(source))
    if not interpreter.is_file() or not os.access(str(interpreter), os.X_OK):
        missing.append(str(interpreter))
    if not module.is_file():
        missing.append(str(module))
    return {
        "kind": "source-tree",
        "path": str(source),
        "interpreter": str(interpreter),
        "native_module": str(module),
        "resolved": "",
        "present": not missing,
        "missing": missing,
    }


def describe_host() -> typing.Dict[str, object]:
    """Which machine the numbers belong to.

    The banner tells the reader to compare runs only on the same host, and the
    process count alone does not identify one: two hosts with the same load
    average and the same number of processes can differ in core count and in
    kernel, and those change every number here.  Each field is read
    independently and any that cannot be read is reported as such rather than
    defaulted, so a partial record is visibly partial.
    """
    def uname(field: str) -> str:
        try:
            with open("/proc/sys/kernel/%s" % field, "rb") as handle:
                return handle.read().decode("utf-8", "replace").strip()
        except OSError:
            return "unavailable"

    return {
        "kernel": uname("osrelease"),
        "machine": os.uname().machine,
        "cpus": os.cpu_count() or 0,
    }


def host_process_count() -> typing.Optional[int]:
    try:
        with os.scandir("/proc") as entries:
            return sum(entry.name.isdigit() for entry in entries)
    except OSError:
        return None


def _clock_ticks() -> int:
    return os.sysconf("SC_CLK_TCK")


def _cpu_seconds(pid: int) -> float:
    with open(f"/proc/{pid}/stat", "rb") as handle:
        fields = handle.read().rsplit(b")", 1)[1].split()
    utime, stime = int(fields[11]), int(fields[12])
    return (utime + stime) / _clock_ticks()


def _rss_kib(pid: int) -> typing.Tuple[int, int]:
    peak, current = -1, -1
    try:
        with open(f"/proc/{pid}/status", "rb") as handle:
            for line in handle:
                if line.startswith(b"VmHWM:"):
                    peak = int(line.split()[1])
                elif line.startswith(b"VmRSS:"):
                    current = int(line.split()[1])
    except OSError:
        pass
    return peak, current


class Session:
    def __init__(self, interval_ms: int) -> None:
        self.pid, self.master = pty.fork()
        if self.pid == 0:
            environment = os.environ.copy()
            if EXECUTABLE:
                environment["LUA_PATH"] = ""
                environment["LUA_CPATH"] = ""
            else:
                environment["LUA_PATH"] = f"{ROOT}/src/?.lua;{ROOT}/src/?/init.lua;;"
                environment["LUA_CPATH"] = f"{ROOT}/build/native/?.so;;"
            environment["TERM"] = "xterm-256color"
            environment["COLORTERM"] = "truecolor"
            environment.pop("NO_COLOR", None)
            environment["XDG_CONFIG_HOME"] = "/nonexistent-wtop-bench"
            arguments = ["--interval", str(interval_ms), "--lang", "en-US"]
            if EXECUTABLE:
                os.execve(EXECUTABLE, [EXECUTABLE, *arguments], environment)
            os.execve(LUA, [LUA, str(ROOT / "src/wtop.lua"), *arguments], environment)
        fcntl.ioctl(
            self.master, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLUMNS, 0, 0)
        )
        os.set_blocking(self.master, False)
        self.output = bytearray()
        self.started = time.monotonic()
        self.first_frame = None

    def pump(self, duration: float) -> None:
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.master], [], [], 0.05)
            if ready:
                try:
                    chunk = os.read(self.master, 65536)
                except (BlockingIOError, OSError):
                    chunk = b""
                if chunk:
                    self.output.extend(chunk)
                    if self.first_frame is None and completed_frame_offset(
                        self.output, b"wtop") is not None:
                        self.first_frame = time.monotonic() - self.started

    def send(self, data: bytes) -> None:
        os.write(self.master, data)

    def wait_for(self, marker: bytes, timeout: float) -> typing.Optional[float]:
        """Time until the destination's complete frame arrives; None on timeout."""
        started = time.monotonic()
        offset = len(self.output)
        deadline = started + timeout
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.master], [], [], 0.005)
            if ready:
                try:
                    chunk = os.read(self.master, 65536)
                except (BlockingIOError, OSError):
                    chunk = b""
                if chunk:
                    self.output.extend(chunk)
                    if completed_frame_offset(self.output, marker, offset) is not None:
                        return time.monotonic() - started
        return None

    def exit(self) -> typing.Tuple[int, int, int]:
        # /proc disappears once the child is reaped, so sample memory first.
        peak, current = _rss_kib(self.pid)
        try:
            self.send(b"q")
        except OSError:
            # A broken bundle may have exited before the first frame. Its
            # failure is reported by the caller, not as an EIO from the PTY.
            pass
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            self.pump(0.05)
            waited, status = os.waitpid(self.pid, os.WNOHANG)
            if waited == self.pid:
                self.pump(0.2)
                return os.WEXITSTATUS(status) if os.WIFEXITED(status) else -1, peak, current
        os.kill(self.pid, signal.SIGKILL)
        os.waitpid(self.pid, 0)
        return -1, peak, current


def _percentile(values: typing.List[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return float("nan")
    index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
    return ordered[index]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", type=pathlib.Path, default=None,
                        help="also write the results as JSON")
    parser.add_argument("--profile", default="unprofiled",
                        help="name of the host/workload budget profile, if one is being checked")
    parser.add_argument("--pages", type=int, default=2,
                        help="pages included in the steady-state CPU sweep (1=overview, 2=+processes)")
    parser.add_argument("--window-seconds", type=float, default=5.0,
                        help="length of each steady-state CPU window")
    parser.add_argument("--latency-samples", type=int, default=20,
                        help="page-switch latency samples")
    parser.add_argument("--startup-timeout", type=float, default=3.0,
                        help="seconds allowed for the first complete frame")
    parser.add_argument("--switch-timeout", type=float, default=2.0,
                        help="seconds allowed for a complete page-switch frame")
    arguments = parser.parse_args()

    if not arguments.profile or len(arguments.profile) > 128:
        parser.error("--profile must be a non-empty name of at most 128 characters")

    if arguments.pages not in (1, 2, 3, 4):
        parser.error("--pages must be in 1..4")
    if arguments.latency_samples < 1 or arguments.latency_samples > 1000:
        parser.error("--latency-samples must be in 1..1000")
    for name in ("window_seconds", "startup_timeout", "switch_timeout"):
        value = getattr(arguments, name)
        if not math.isfinite(value) or value <= 0 or value > 60:
            parser.error("--%s must be finite and in (0, 60]" % name.replace("_", "-"))

    page_keys = {1: b"1", 2: b"2", 6: b"6", 7: b"7"}
    selected = [1, 2, 6, 7][:arguments.pages]

    # A named subject that is not there is a refusal, not a measurement.  The
    # alternative is execve failing inside the forked child, which surfaces as
    # "no first frame within 3 seconds" -- a statement about the application
    # that is really a statement about a typo in a path, and the kind of wrong
    # answer this project keeps refusing to file.
    subject = describe_subject()
    if not subject["present"]:
        raise SystemExit(
            "benchmark: refusing to measure %s: %s (%s)"
            % (subject["kind"], subject["path"],
               "not an executable file" if subject["kind"] == "bundle"
               else "missing: " + ", ".join(subject["missing"])))

    session = Session(interval_ms=1000)
    session.pump(arguments.startup_timeout)
    if session.first_frame is None:
        exit_code, _, _ = session.exit()
        raise SystemExit("benchmark: no complete first frame within %.1f seconds "
                         "(subject exit %s)" % (arguments.startup_timeout, exit_code))

    results: typing.Dict[str, object] = {
        "measurement_version": 3,
        "profile": arguments.profile,
        "subject": subject,
        "host": describe_host(),
        "host_processes": None,
        "host_processes_samples": [],
        "settings": {
            "pages": selected,
            "window_seconds": arguments.window_seconds,
            "latency_samples": arguments.latency_samples,
            "columns": COLUMNS,
            "rows": ROWS,
            "interval_ms": 1000,
            "startup_timeout": arguments.startup_timeout,
            "switch_timeout": arguments.switch_timeout,
        },
        "first_frame_ms": round(session.first_frame * 1000, 1),
        "steady_cpu_percent": {},
    }
    def record_process_count(phase: str) -> None:
        count = host_process_count()
        results["host_processes_samples"].append({"phase": phase, "count": count})
        if phase == "first_frame":
            results["host_processes"] = count

    record_process_count("first_frame")

    for page in selected:
        session.send(page_keys[page])
        session.pump(2.0)
        record_process_count("page_%d_start" % page)
        before = _cpu_seconds(session.pid)
        started = time.monotonic()
        session.pump(arguments.window_seconds)
        elapsed = time.monotonic() - started
        after = _cpu_seconds(session.pid)
        record_process_count("page_%d_end" % page)
        results["steady_cpu_percent"]["page_%d" % page] = round(
            (after - before) / elapsed * 100.0, 2
        )

    latencies = []
    latencies_by_target: typing.Dict[int, typing.List[float]] = {}
    # A latency sample only measures something if the keypress changes the page.
    # Re-selecting the page already on screen redraws nothing, so the marker
    # never arrives and the run aborts -- which is why `--pages 1`, a value the
    # help text offers, could never complete a run at all: every sample asked
    # the application to stay where it already was.  The rotation is therefore
    # built to start on a page that is not the one currently displayed.
    displayed = selected[-1]
    if len(selected) > 1:
        rotation = selected
    else:
        elsewhere = [page for page in page_keys if page != displayed]
        if not elsewhere:
            raise SystemExit("benchmark: no second page to measure a switch into")
        rotation = [elsewhere[0], displayed]
    for index in range(arguments.latency_samples):
        target = rotation[index % len(rotation)]
        session.output.clear()
        record_process_count("latency_%d" % index)
        session.send(page_keys[target])
        observed = session.wait_for(PAGE_MARKERS[target], timeout=arguments.switch_timeout)
        if observed is None:
            session.exit()
            raise SystemExit(
                f"benchmark: page {target} marker never appeared; latency run aborted"
            )
        duration_ms = observed * 1000.0
        latencies.append(duration_ms)
        latencies_by_target.setdefault(target, []).append(duration_ms)
        # Keep draining between keypresses: a following automatic refresh can
        # still fill the PTY and turn our own unconsumed output into latency.
        session.pump(0.1)
    record_process_count("end")
    results["input_latency_ms"] = {
        "p50": round(_percentile(latencies, 0.5), 1),
        "p95": round(_percentile(latencies, 0.95), 1),
        "max": round(max(latencies), 1),
        "samples": len(latencies),
    }
    for page, values in sorted(latencies_by_target.items()):
        prefix = "page_%d_" % page
        results["input_latency_ms"][prefix + "p50"] = round(_percentile(values, 0.5), 1)
        results["input_latency_ms"][prefix + "p95"] = round(_percentile(values, 0.95), 1)
        results["input_latency_ms"][prefix + "max"] = round(max(values), 1)
        results["input_latency_ms"][prefix + "samples"] = len(values)

    exit_code, rss_peak, rss_current = session.exit()
    results["exit_code"] = exit_code
    results["rss_peak_kib"] = rss_peak
    results["rss_steady_kib"] = rss_current

    print("wtop performance benchmark (fixed script; compare same host only)")
    print(f"  subject.kind: {subject['kind']}")
    print(f"  subject.path: {subject['path']}")
    host = results["host"]
    for key, value in host.items():
        print(f"  host.{key}: {value}")
    for key, value in results.items():
        if key in ("subject", "host"):
            continue
        if key == "host_processes_samples":
            counts = [item["count"] for item in value if item["count"] is not None]
            print("  host_processes_samples: %d observations, %s..%s" %
                  (len(value), min(counts) if counts else "unavailable",
                   max(counts) if counts else "unavailable"))
            continue
        if isinstance(value, dict):
            for nested_key, nested in value.items():
                print(f"  {key}.{nested_key}: {nested}")
        else:
            print(f"  {key}: {value}")
    if arguments.json:
        arguments.json.write_text(
            json.dumps(results, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        print(f"  json: {arguments.json}")
    if exit_code != 0:
        raise SystemExit("benchmark: clean exit failed")


if __name__ == "__main__":
    main()
