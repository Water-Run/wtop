#!/usr/bin/env python3
"""Validate installed structured-output contracts without host-specific values."""

from __future__ import annotations

import json
import math
import sys


def require_mapping(value: object, name: str) -> dict:
    assert isinstance(value, dict), f"{name} must be an object"
    return value


def require_list(value: object, name: str) -> list:
    assert isinstance(value, list), f"{name} must be an array"
    return value


def validate(document: object, mode: str) -> None:
    assert mode in ("snapshot", "agent", "memory-bandwidth"), "unknown structured-output contract"
    document = require_mapping(document, "document")
    privilege = require_mapping(document.get("privilege"), "privilege")
    assert privilege.get("mode") in ("user", "root", "unknown")

    if mode == "memory-bandwidth":
        assert document.get("schema") == "dev.waterrun.wtop.memory-bandwidth/v1"
        assert document.get("mode") in ("list", "measure")
        assert document.get("platform") in ("Linux", "Darwin", "Windows", "unknown")
        assert require_mapping(document.get("producer"), "producer").get("name") == "wtop"
        assert isinstance(privilege.get("root"), bool) and isinstance(privilege.get("requested"), bool)
        for name in ("captured_monotonic_ns", "captured_unix_ns"):
            assert type(document.get(name)) is int and document[name] >= 0
        result = require_mapping(document.get("result"), "result")
        assert result.get("status") == document.get("status")
        assert result["status"] in ("ok", "unavailable", "denied", "error")
        if result["status"] != "ok":
            assert isinstance(document.get("reason"), str) and document["reason"]
        require_list(result.get("sections"), "result.sections")
        if document["mode"] == "list":
            assert document.get("requested_pmu") == "list"
            assert result["sections"] == [] and "entity" not in result
            items = require_list(document.get("pmus"), "pmus")
            assert len(items) <= 256 and isinstance(document.get("pmus_truncated"), bool)
            ids = set()
            for item in items:
                item = require_mapping(item, "pmus[]")
                assert isinstance(item.get("id"), str) and item["id"] not in ids
                ids.add(item["id"])
                assert isinstance(item.get("source"), str) and isinstance(item.get("events_truncated"), bool)
        else:
            assert "pmus" not in document and "pmus_truncated" not in document
        if document["mode"] == "measure" and result.get("entity") is not None:
            fields = require_mapping(require_mapping(result["entity"], "entity").get("metrics"), "metrics")
            scope = require_mapping(fields.get("measurement_scope"), "measurement_scope").get("value")
            assert scope == ("controller_pmu" if document.get("requested_pmu") else "system")
            sample_field = fields.get("counter_samples")
            if sample_field is not None:
                samples = require_list(require_mapping(sample_field, "counter_samples").get("value"), "samples")
                assert len(samples) <= 1024
                totals = {"read": 0.0, "write": 0.0}
                for row in samples:
                    row = require_mapping(row, "samples[]")
                    assert row.get("direction") in totals and isinstance(row.get("pmu"), str)
                    assert isinstance(row.get("event"), str) and isinstance(row.get("instance"), str)
                    rate = row.get("bytes_per_second")
                    if rate is not None:
                        assert type(rate) in (int, float) and math.isfinite(rate) and rate >= 0
                        assert row.get("quality") in ("fresh", "estimated")
                        for key in ("runtime_ns", "count"):
                            value = row.get(key)
                            assert type(value) in (int, float) and math.isfinite(value)
                        assert row["runtime_ns"] > 0 and row["count"] >= 0
                        running = row.get("running_percent")
                        assert type(running) in (int, float) and math.isfinite(running) and 0 < running <= 100
                        totals[row["direction"]] += rate
                    else:
                        assert row.get("quality") in ("unavailable", "error")
                details = require_mapping(result.get("details"), "details")
                assert details.get("counter_samples_total", -1) >= len(samples)
                assert isinstance(details.get("counter_samples_truncated"), bool)
                if not details["counter_samples_truncated"]:
                    for direction, total in totals.items():
                        value = fields[direction + "_bandwidth"].get("value")
                        if value is not None:
                            assert type(value) in (int, float) and math.isfinite(value) and value >= 0
                            assert math.isclose(value, total, rel_tol=1e-9, abs_tol=1e-6)
        if document["mode"] == "measure" and result["status"] == "ok":
            assert isinstance(result.get("entity"), dict)
        if document["platform"] != "Linux":
            assert result["status"] == "unavailable" and document.get("reason") == "unsupported_on_this_platform"
        assert "processes" not in document and "connections" not in document
    elif mode == "snapshot":
        assert document.get("schema") == "dev.waterrun.wtop.snapshot/v1"
        cpu_info = require_mapping(document.get("cpu_info"), "cpu_info")
        require_mapping(cpu_info.get("identity"), "cpu_info.identity")
        require_mapping(cpu_info.get("topology"), "cpu_info.topology")
        require_list(cpu_info.get("core_types"), "cpu_info.core_types")
        require_list(cpu_info.get("caches"), "cpu_info.caches")
        require_list(require_mapping(document.get("gpus"), "gpus").get("devices"), "gpus.devices")
        require_list(
            require_mapping(document.get("sensors"), "sensors").get("devices"),
            "sensors.devices",
        )
        require_list(require_mapping(document.get("power"), "power").get("zones"), "power.zones")
        require_mapping(document.get("quality"), "quality")
    else:
        assert document.get("schema") == "dev.waterrun.wtop.agent/v1"
        metrics = require_mapping(document.get("metrics"), "metrics")
        for name in ("cpu", "gpu", "power", "sensors"):
            require_mapping(metrics.get(name), f"metrics.{name}")
        top = require_mapping(document.get("top"), "top")
        require_list(top.get("sensors"), "top.sensors")
        require_list(document.get("signals"), "signals")
        require_list(document.get("data_quality"), "data_quality")


def main() -> None:
    assert len(sys.argv) == 2 and sys.argv[1] in ("snapshot", "agent", "memory-bandwidth"), (
        "usage: json_contract_smoke.py snapshot|agent|memory-bandwidth"
    )
    validate(json.load(sys.stdin), sys.argv[1])


if __name__ == "__main__":
    main()
