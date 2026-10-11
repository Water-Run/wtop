#!/usr/bin/env python3
"""Check a completed wtop benchmark against a host/workload-specific budget.

The budget is explicit because a release limit measured on one machine cannot
honestly be applied to another. The result must identify the same profile,
host, workload size at measured phases, subject and measurement protocol
before numbers are compared.
"""

import argparse
import json
import math
import pathlib
import typing


SETTINGS = ("pages", "window_seconds", "latency_samples", "columns", "rows", "interval_ms")
HOST = ("kernel", "machine", "cpus")


def _number(value: object) -> bool:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    try:
        return math.isfinite(value) and value >= 0
    except OverflowError:
        return False


def _metric(result: typing.Dict[str, object], name: str) -> object:
    value: object = result
    for component in name.split("."):
        if not isinstance(value, dict) or component not in value:
            raise KeyError(name)
        value = value[component]
    return value


def evaluate(result: typing.Dict[str, object], budget: typing.Dict[str, object]) -> typing.List[str]:
    failures: typing.List[str] = []
    if result.get("measurement_version") != 3:
        failures.append("result lacks complete-frame and workload sampling (version 3)")
    profile = budget.get("profile")
    if not isinstance(profile, str) or not profile or profile == "unprofiled":
        failures.append("budget requires a named host/workload profile")
    elif result.get("profile") != profile:
        failures.append("profile differs: result %r, budget %r" % (result.get("profile"), profile))
    subject = result.get("subject")
    if budget.get("subject_kind") != "bundle" or not isinstance(subject, dict) \
            or subject.get("kind") != "bundle" or subject.get("present") is not True:
        failures.append("release budget requires a present bundle subject")
    subject_path = budget.get("subject_path")
    if not isinstance(subject_path, str) or not subject_path or len(subject_path) > 4096:
        failures.append("budget requires a bundle subject_path")
    elif isinstance(subject, dict) and subject.get("path") != subject_path:
        failures.append("bundle path differs: result %r, budget %r" %
                        (subject.get("path"), subject_path))
    if result.get("exit_code") != 0:
        failures.append("benchmark subject did not exit cleanly")

    expected_host, actual_host = budget.get("host"), result.get("host")
    if not isinstance(expected_host, dict) or not isinstance(actual_host, dict):
        failures.append("host identity is missing")
    else:
        for key in HOST:
            if key not in expected_host or expected_host[key] != actual_host.get(key):
                failures.append("host.%s differs or is missing" % key)

    workload = budget.get("host_processes")
    process_count = result.get("host_processes")
    workload_valid = isinstance(workload, dict) and all(
        key in workload for key in ("min", "max")) and not any(
        type(workload[key]) is not int or workload[key] < 0
        for key in ("min", "max")) and workload["min"] <= workload["max"]
    if not workload_valid:
        failures.append("budget requires a nonnegative host_processes min/max range")
    elif type(process_count) is not int or not workload["min"] <= process_count <= workload["max"]:
        failures.append("host process count is outside the budget workload range")

    observations = result.get("host_processes_samples")
    expected_phases = {"first_frame", "end"}
    if isinstance(budget.get("settings"), dict):
        selected = budget["settings"].get("pages")
        count = budget["settings"].get("latency_samples")
        if isinstance(selected, list):
            for page in selected:
                if type(page) is int:
                    expected_phases.update(("page_%d_start" % page, "page_%d_end" % page))
        if type(count) is int and 0 <= count <= 1000:
            expected_phases.update("latency_%d" % index for index in range(count))
    if not isinstance(observations, list):
        failures.append("workload samples are missing")
    else:
        phases = {}
        for item in observations:
            if not isinstance(item, dict) or not isinstance(item.get("phase"), str):
                failures.append("workload sample has no phase")
                continue
            phase, count = item["phase"], item.get("count")
            if phase in phases:
                failures.append("duplicate workload phase %s" % phase)
                continue
            phases[phase] = count
            if type(count) is not int or count < 0:
                failures.append("workload phase %s has no valid process count" % phase)
            elif workload_valid and not workload["min"] <= count <= workload["max"]:
                failures.append("workload phase %s is outside the process range" % phase)
        for phase in sorted(expected_phases - set(phases)):
            failures.append("missing workload phase %s" % phase)
        for phase in sorted(set(phases) - expected_phases):
            failures.append("unexpected workload phase %s" % phase)
        if "first_frame" in phases and phases["first_frame"] != process_count:
            failures.append("host process count differs from first-frame sample")

    expected_settings, actual_settings = budget.get("settings"), result.get("settings")
    pages: typing.List[int] = []
    if not isinstance(expected_settings, dict) or not isinstance(actual_settings, dict):
        failures.append("benchmark settings are missing")
    else:
        for key in SETTINGS:
            if key not in expected_settings or expected_settings[key] != actual_settings.get(key):
                failures.append("settings.%s differs or is missing" % key)
        selected = expected_settings.get("pages")
        if isinstance(selected, list) and selected and all(type(item) is int for item in selected):
            pages = selected
        else:
            failures.append("budget settings.pages must name measured page numbers")
        if 1 not in pages or 2 not in pages:
            failures.append("performance gate must measure Overview and Processes")
        window = expected_settings.get("window_seconds")
        samples = expected_settings.get("latency_samples")
        if not _number(window) or window < 5:
            failures.append("performance gate requires at least 5 seconds per steady window")
        if type(samples) is not int or samples < 20:
            failures.append("performance gate requires at least 20 page switches")

    maximum = budget.get("maximum")
    if not isinstance(maximum, dict):
        failures.append("budget maximum must be a metric-to-limit object")
        maximum = {}
    required = {"first_frame_ms", "rss_peak_kib", "input_latency_ms.p95"}
    required.update("steady_cpu_percent.page_%d" % page for page in pages)
    latency_pages = pages if len(pages) > 1 else \
        [2 if pages[0] == 1 else 1, pages[0]] if pages else []
    required.update("input_latency_ms.page_%d_p95" % page for page in latency_pages)
    for key in sorted(required - set(maximum)):
        failures.append("budget lacks required metric %s" % key)
    for name, limit in sorted(maximum.items()):
        if not isinstance(name, str) or not name or not _number(limit):
            failures.append("invalid budget metric or limit %r" % name)
            continue
        try:
            value = _metric(result, name)
        except KeyError:
            failures.append("result lacks budget metric %s" % name)
            continue
        if not _number(value):
            failures.append("result metric %s is not a finite nonnegative number" % name)
        elif value > limit:
            failures.append("%s exceeds budget: %s > %s" % (name, value, limit))

    latency = result.get("input_latency_ms")
    if isinstance(latency, dict) and isinstance(actual_settings, dict):
        if latency.get("samples") != actual_settings.get("latency_samples"):
            failures.append("latency sample count differs from benchmark settings")
        for page in latency_pages:
            if not _number(latency.get("page_%d_samples" % page)) \
                    or latency["page_%d_samples" % page] < 1:
                failures.append("page %d has no measured switch" % page)
    else:
        failures.append("latency measurements are missing")
    return failures


def _read(path: pathlib.Path, name: str) -> typing.Dict[str, object]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, UnicodeError, ValueError) as error:
        raise SystemExit("performance budget: cannot read %s %s: %s" % (name, path, error))
    if not isinstance(value, dict):
        raise SystemExit("performance budget: %s must be a JSON object" % name)
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result", type=pathlib.Path, required=True)
    parser.add_argument("--budget", type=pathlib.Path, required=True)
    arguments = parser.parse_args()
    result = _read(arguments.result, "result")
    budget = _read(arguments.budget, "budget")
    failures = evaluate(result, budget)
    if failures:
        for failure in failures:
            print("performance budget: " + failure)
        raise SystemExit(1)
    print("performance budget: %s passed (%d metric limits)" %
          (budget["profile"], len(budget["maximum"])))


if __name__ == "__main__":
    main()
