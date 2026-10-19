#!/usr/bin/env python3
"""The performance gate rejects incomplete or mismatched measurements."""

import copy
import json
import math
import pathlib
import subprocess
import sys
import tempfile
import os
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import check_perf_budget as gate  # noqa: E402
import perf_benchmark as benchmark  # noqa: E402


def fixture():
    result = {
        "measurement_version": 4, "profile": "old-test-machine", "exit_code": 0, "subject_uid": 1000,
        "subject": {"kind": "bundle", "present": True, "path": "dist/wtop/wtop", "runtime_sha256": "a"*64},
        "host": {"kernel": "test-kernel", "machine": "x86_64", "cpus": 2},
        "host_processes": 1000,
        "host_processes_samples": [
            {"phase": phase, "count": 1000} for phase in
            (["first_frame", "page_1_start", "page_1_end",
              "page_2_start", "page_2_end"] +
             ["latency_%d" % index for index in range(20)] + ["end"])
        ],
        "settings": {"pages": [1, 2], "window_seconds": 5.0,
                     "latency_samples": 20, "columns": 120, "rows": 34,
                     "interval_ms": 1000, "resource_sample_ms": 200},
        "first_frame_ms": 300.0, "rss_peak_kib": 12000, "family_sampled_pss_peak_kib": 45000,
        "steady_cpu_percent": {"page_1": 3.0, "page_2": 4.0},
        "input_latency_ms": {"p95": 30.0, "samples": 20,
                             "page_1_p95": 25.0, "page_1_samples": 10,
                             "page_2_p95": 30.0, "page_2_samples": 10},
    }
    samples=[]
    for index in range(61):
        t=index/5.0
        family_ticks=1000+int(3*min(t,6)+4*max(t-6,0))
        samples.append({"cpu_status":"observed","memory_status":"observed",
                        "family_ticks":family_ticks,"own_ticks":100+index,
                        "pss_kib":45000,"sample_started":t,"sample_finished":t+.001})
    result["observer_uid"]=1000
    result["measurement_tools_sha256"]={"perf_benchmark.py":"a"*64,"perf_process_family.py":"b"*64}
    result["resource_accounting"]={"cpu_scope":"observed_descendants_and_waited_children",
        "memory_scope":"sampled_family_pss","cpu_status":"observed","memory_status":"observed",
        "hugetlb_status":"known_zero","sample_bound_exceeded":False,
        "sample_period_ms":200,"clock_ticks_per_second":100,"observer_cpu_seconds":.01,"samples":samples}
    result["cpu_windows"]={"page_1":{"before":samples[0],"after":samples[25],"seconds":5},
                           "page_2":{"before":samples[30],"after":samples[55],"seconds":5}}
    budget = {
        "profile": "old-test-machine", "subject_kind": "bundle", "subject_uid": 1000,
        "resource_observer": {"maximum_gap_ms": 400, "maximum_bracket_ms": 50, "maximum_cpu_percent": 5},
        "subject_path": "dist/wtop/wtop",
        "host": copy.deepcopy(result["host"]),
        "host_processes": {"min": 900, "max": 1100},
        "settings": {key: result["settings"][key] for key in gate.SETTINGS},
        "maximum": {"first_frame_ms": 500, "family_sampled_pss_peak_kib": 60000,
                    "steady_cpu_percent.page_1": 5,
                    "steady_cpu_percent.page_2": 6,
                    "input_latency_ms.p95": 50,
                    "input_latency_ms.page_1_p95": 50,
                    "input_latency_ms.page_2_p95": 50},
    }
    return result, budget


def rejects(result, budget, fragment):
    failures = gate.evaluate(result, budget)
    assert any(fragment in failure for failure in failures), failures


def check_pump_deadline():
    # Advancing clocks make the deadline property deterministic even on a
    # loaded runner. Exercise idle waits, sampler cost and repeated ready data.
    for sample_cost, ready in [(0, False), (0.004, False), (0.006, False),
                               (0, True), (0, "one_frame")]:
        clock, timeouts, reads = [0.0], [], []
        session = benchmark.Session.__new__(benchmark.Session)
        session.master, session.output = 123, bytearray()
        session.first_frame, session.started = None, 0.0
        class Sampler:
            def sample(self):
                clock[0] += sample_cost
        session.resources = Sampler()
        def select(readers, writers, errors, timeout):
            timeouts.append(timeout)
            assert 0 <= timeout <= max(0, 0.005-clock[0])+1e-12
            available = ready is True or ready == "one_frame" and not reads
            clock[0] += min(0.001, timeout) if available else timeout
            return ([123], [], []) if available else ([], [], [])
        def read(fd, limit):
            reads.append(fd)
            return b"wtop\x1b[0m"
        with patch.object(benchmark.time, "monotonic", lambda: clock[0]), \
             patch.object(benchmark.select, "select", select), \
             patch.object(benchmark.os, "read", read):
            session.pump(0.005)
        assert clock[0] <= max(0.005, sample_cost)+1e-12
        if sample_cost > 0.005:
            assert not timeouts
        if ready:
            assert reads and session.first_frame is not None


def main():
    check_pump_deadline()
    from test_perf_process_family import main as check_family
    check_family()
    # A visible tab label is not a completed page. The encoder emits its
    # standalone reset only after all changed rows have been written.
    stream = bytearray(b"wtop Overview Processes \x1b[0;37m")
    assert benchmark.completed_frame_offset(stream, b"wtop") is None
    assert benchmark.completed_frame_offset(stream, benchmark.PAGE_MARKERS[2]) is None
    stream.extend(b"\x1b[0m")
    assert benchmark.completed_frame_offset(stream, b"wtop") == len(stream)
    start = len(stream)
    stream.extend(b"Command \x1b[0;37m")
    assert benchmark.completed_frame_offset(stream, benchmark.PAGE_MARKERS[2], start) is None
    stream.extend(b"\x1b[0m")
    assert benchmark.completed_frame_offset(stream, benchmark.PAGE_MARKERS[2], start) == len(stream)

    result, budget = fixture()
    assert not gate.evaluate(result, budget)
    bad = copy.deepcopy(result)
    bad["first_frame_ms"] = 501
    rejects(bad, budget, "first_frame_ms exceeds budget")
    bad = copy.deepcopy(result)
    bad["measurement_version"] = 1
    rejects(bad, budget, "workload sampling")
    bad = copy.deepcopy(result)
    bad["measurement_version"] = 3
    rejects(bad, budget, "process-family")
    bad = copy.deepcopy(result)
    bad["steady_cpu_percent"]["page_1"] = 0
    rejects(bad, budget, "disagrees with observed counters")
    # The rate and its divisor used to agree with each other while the
    # divisor disagreed with the actual observation times. Both forged
    # windows and detached counter records must fail the release gate.
    bad = copy.deepcopy(result)
    for key, window in bad["cpu_windows"].items():
        window["seconds"] *= 1000
        bad["steady_cpu_percent"][key] /= 1000
    rejects(bad, budget, "duration disagrees with observed bounds")
    bad = copy.deepcopy(result)
    window = bad["cpu_windows"]["page_1"]
    window["before"] = copy.deepcopy(window["before"])
    window["before"]["family_ticks"] = window["after"]["family_ticks"]
    bad["steady_cpu_percent"]["page_1"] = 0
    rejects(bad, budget, "not saved resource observations")
    for value in (None, True, math.nan, math.inf, -1):
        bad = copy.deepcopy(result)
        bad["cpu_windows"]["page_1"]["before"]["sample_started"] = value
        rejects(bad, budget, "CPU observation bounds")
    bad = copy.deepcopy(result)
    bad["cpu_windows"]["page_1"]["before"]["sample_finished"] = 6
    rejects(bad, budget, "CPU observation bounds")
    bad = copy.deepcopy(result)
    samples = bad["resource_accounting"]["samples"]
    bad["cpu_windows"]["page_1"] = {"before": samples[0], "after": samples[1], "seconds": .2}
    bad["steady_cpu_percent"]["page_1"] = 0
    rejects(bad, budget, "shorter than the requested duration")
    bad = copy.deepcopy(result)
    bad["cpu_windows"]["page_2"] = copy.deepcopy(bad["cpu_windows"]["page_1"])
    bad["steady_cpu_percent"]["page_2"] = bad["steady_cpu_percent"]["page_1"]
    rejects(bad, budget, "overlap or reverse page order")
    bad = copy.deepcopy(result)
    bad["resource_accounting"]["memory_status"] = "denied"
    rejects(bad, budget, "memory_status is incomplete")
    bad = copy.deepcopy(result)
    bad["family_sampled_pss_peak_kib"] = bad["rss_peak_kib"]
    rejects(bad, budget, "PSS peak disagrees")
    bad = copy.deepcopy(result)
    bad["subject"]["kind"] = "source-tree"
    rejects(bad, budget, "bundle subject")
    bad = copy.deepcopy(result)
    bad["subject"]["path"] = "dist/wtop-onefile"
    rejects(bad, budget, "bundle path differs")
    bad = copy.deepcopy(budget)
    bad.pop("subject_path")
    rejects(result, bad, "requires a bundle subject_path")
    bad = copy.deepcopy(result)
    bad["host_processes"] = 4
    rejects(bad, budget, "process count")
    bad = copy.deepcopy(result)
    bad["host_processes_samples"][10]["count"] = 4
    rejects(bad, budget, "workload phase latency_5 is outside")
    bad = copy.deepcopy(result)
    bad["host_processes_samples"].pop(10)
    rejects(bad, budget, "missing workload phase latency_5")
    bad = copy.deepcopy(result)
    bad["host_processes_samples"].append(
        {"phase": "page_1_start", "count": 1000})
    rejects(bad, budget, "duplicate workload phase page_1_start")
    bad = copy.deepcopy(result)
    bad["host_processes_samples"][0]["count"] = None
    rejects(bad, budget, "first_frame has no valid process count")
    bad = copy.deepcopy(result)
    bad["settings"]["latency_samples"] = 2
    rejects(bad, budget, "settings.latency_samples")
    short_result, short_budget = fixture()
    short_result["settings"]["window_seconds"] = 0.2
    short_budget["settings"]["window_seconds"] = 0.2
    short_result["settings"]["latency_samples"] = 4
    short_result["input_latency_ms"]["samples"] = 4
    short_result["host_processes_samples"] = [
        sample for sample in short_result["host_processes_samples"]
        if not sample["phase"].startswith("latency_")
        or int(sample["phase"].split("_")[1]) < 4]
    short_budget["settings"]["latency_samples"] = 4
    rejects(short_result, short_budget, "at least 5 seconds")
    rejects(short_result, short_budget, "at least 20 page switches")
    bad = copy.deepcopy(budget)
    del bad["maximum"]["steady_cpu_percent.page_2"]
    rejects(result, bad, "lacks required metric steady_cpu_percent.page_2")
    bad = copy.deepcopy(result)
    bad["input_latency_ms"]["page_1_p95"] = math.nan
    rejects(bad, budget, "not a finite")
    assert not gate._number(10 ** 1000)
    bad = copy.deepcopy(result)
    bad["subject_uid"] = 0
    rejects(bad,budget,"subject UID differs")
    bad = copy.deepcopy(result)
    del bad["subject"]["runtime_sha256"]
    rejects(bad,budget,"fingerprint")
    bad = copy.deepcopy(result)
    bad["resource_accounting"]["observer_cpu_seconds"] = 100
    rejects(bad,budget,"observer CPU")
    bad = copy.deepcopy(result)
    bad["resource_accounting"]["samples"][1]["sample_finished"] += 1
    rejects(bad,budget,"observer bracket")

    with tempfile.TemporaryDirectory(prefix="wtop-perf-budget-") as temporary:
        directory = pathlib.Path(temporary)
        result_path, budget_path = directory / "result.json", directory / "budget.json"
        result_path.write_text(json.dumps(result), encoding="utf-8")
        budget_path.write_text(json.dumps(budget), encoding="utf-8")
        command = [sys.executable, str(ROOT / "tools/check_perf_budget.py"),
                   "--result", str(result_path), "--budget", str(budget_path)]
        passed = subprocess.run(command, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, universal_newlines=True)
        assert passed.returncode == 0 and "passed" in passed.stdout, passed
        result["first_frame_ms"] = 501
        result_path.write_text(json.dumps(result), encoding="utf-8")
        failed = subprocess.run(command, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, universal_newlines=True)
        assert failed.returncode != 0 and "first_frame_ms" in failed.stdout, failed
        broken = directory / "broken-bundle"
        broken.write_text("#!/bin/sh\nexit 5\n", encoding="utf-8")
        broken.chmod(0o755)
        environment = os.environ.copy()
        environment["WTOP_BENCH_EXECUTABLE"] = str(broken)
        crashed = subprocess.run(
            [sys.executable, str(ROOT / "tools/perf_benchmark.py"),
             "--pages", "1", "--window-seconds", "0.1",
             "--latency-samples", "1", "--startup-timeout", "0.2"],
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True)
        assert crashed.returncode != 0 and "no complete first frame" in crashed.stderr \
            and "Traceback" not in crashed.stderr, crashed
    print("performance budget gate: matching profile passes; mismatches and regressions fail")


if __name__ == "__main__":
    main()
