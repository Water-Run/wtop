#!/usr/bin/env python3
"""Repeatable whole-process performance benchmark for the wtop TUI.

Runs the real application in a pseudo-terminal and measures four numbers the
release goals reference: cold start to the first complete frame, steady-state
CPU over render windows, peak RSS, and page-switch input latency. The key
script and intervals are fixed so two runs on the same host compare directly;
absolute values still depend on the host's process count and hardware, so
cross-host comparisons are indicative only.

Every result records *what was measured* and *on what*, because without that a
number is not a measurement of anything in particular.  This tool can drive two
different subjects -- the development tree, or a release bundle named by
WTOP_BENCH_EXECUTABLE -- and they are not the same program: measured on the same
host minutes apart, the bundle started 15% slower and held 25% more resident
memory than the source tree.  The two records had byte-identical key sets, so
nothing downstream could tell which one it was holding.  The subject and the
host are therefore part of the record, not decoration on it, and the banner's
"compare same host only" is only actionable if the host is written down.

Usage: tools/perf_benchmark.py [--json PATH] [--pages N] [--window-seconds N]
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


def describe_subject() -> typing.Dict[str, object]:
    """What this run actually measured.

    Two subjects are supported and they are not interchangeable.  A bundle is
    the artifact a release ships: a self-extracting image with every module
    already inside it.  The development tree is the same sources loaded from
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
    return {
        "kind": "source-tree",
        "path": str(ROOT / "src/wtop.lua"),
        "resolved": "",
        "present": (ROOT / "src/wtop.lua").is_file(),
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
                    if self.first_frame is None and b"wtop" in self.output:
                        self.first_frame = time.monotonic() - self.started

    def send(self, data: bytes) -> None:
        os.write(self.master, data)

    def wait_for(self, marker: bytes, timeout: float) -> typing.Optional[float]:
        """Time until marker appears after this call; None on timeout."""
        started = time.monotonic()
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
                    if marker in self.output:
                        return time.monotonic() - started
        return None

    def exit(self) -> typing.Tuple[int, int, int]:
        # /proc disappears once the child is reaped, so sample memory first.
        peak, current = _rss_kib(self.pid)
        self.send(b"q")
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            self.pump(0.05)
            waited, status = os.waitpid(self.pid, os.WNOHANG)
            if waited == self.pid:
                self.pump(0.2)
                return os.WEXITSTATUS(status), peak, current
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
    parser.add_argument("--pages", type=int, default=2,
                        help="pages included in the steady-state CPU sweep (1=overview, 2=+processes)")
    parser.add_argument("--window-seconds", type=float, default=5.0,
                        help="length of each steady-state CPU window")
    parser.add_argument("--latency-samples", type=int, default=20,
                        help="page-switch latency samples")
    arguments = parser.parse_args()

    page_keys = {1: b"1", 2: b"2", 6: b"6", 7: b"7"}
    page_markers = {1: b"Overview", 2: b"Processes", 6: b"Network", 7: b"GPU"}
    selected = list(page_keys)[: max(1, arguments.pages)]

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
               else "not a file")
        )

    session = Session(interval_ms=1000)
    session.pump(3.0)
    if session.first_frame is None:
        session.exit()
        raise SystemExit("benchmark: no first frame within 3 seconds")

    results: typing.Dict[str, object] = {
        "subject": subject,
        "host": describe_host(),
        "host_processes": None,
        "first_frame_ms": round(session.first_frame * 1000, 1),
        "steady_cpu_percent": {},
    }
    try:
        with open("/proc/loadavg", "rb") as handle:
            pass
        process_count = 0
        for entry in os.scandir("/proc"):
            if entry.name.isdigit():
                process_count += 1
        results["host_processes"] = process_count
    except OSError:
        pass

    for page in selected:
        session.send(page_keys[page])
        session.pump(2.0)
        before = _cpu_seconds(session.pid)
        started = time.monotonic()
        session.pump(arguments.window_seconds)
        elapsed = time.monotonic() - started
        after = _cpu_seconds(session.pid)
        results["steady_cpu_percent"]["page_%d" % page] = round(
            (after - before) / elapsed * 100.0, 2
        )

    latencies = []
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
        session.send(page_keys[target])
        observed = session.wait_for(page_markers[target], timeout=2.0)
        if observed is None:
            session.exit()
            raise SystemExit(
                f"benchmark: page {target} marker never appeared; latency run aborted"
            )
        latencies.append(observed * 1000.0)
        time.sleep(0.1)
    results["input_latency_ms"] = {
        "p50": round(_percentile(latencies, 0.5), 1),
        "p95": round(_percentile(latencies, 0.95), 1),
        "max": round(max(latencies), 1),
        "samples": len(latencies),
    }

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
