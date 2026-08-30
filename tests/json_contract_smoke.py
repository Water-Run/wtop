#!/usr/bin/env python3
"""Validate installed structured-output contracts without host-specific values."""

from __future__ import annotations

import json
import sys


def require_mapping(value: object, name: str) -> dict:
    assert isinstance(value, dict), f"{name} must be an object"
    return value


def require_list(value: object, name: str) -> list:
    assert isinstance(value, list), f"{name} must be an array"
    return value


def main() -> None:
    assert len(sys.argv) == 2 and sys.argv[1] in ("snapshot", "agent"), (
        "usage: json_contract_smoke.py snapshot|agent"
    )
    document = require_mapping(json.load(sys.stdin), "document")
    privilege = require_mapping(document.get("privilege"), "privilege")
    assert privilege.get("mode") in ("user", "root", "unknown")

    if sys.argv[1] == "snapshot":
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


if __name__ == "__main__":
    main()
