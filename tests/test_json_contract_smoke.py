#!/usr/bin/env python3
"""Reject damaged bandwidth exports before accepting installed programs."""

import copy
import unittest

from json_contract_smoke import validate


def measurement():
    return {
        "schema": "dev.waterrun.wtop.memory-bandwidth/v1", "mode": "measure",
        "platform": "Linux", "producer": {"name": "wtop", "version": "0.2.0"},
        "privilege": {"mode": "user", "root": False, "requested": False},
        "status": "ok", "captured_monotonic_ns": 1, "captured_unix_ns": 2,
        "result": {"status": "ok", "sections": [], "details": {
            "counter_samples_total": 1, "counter_samples_truncated": False},
            "entity": {"metrics": {
                "measurement_scope": {"value": "system"},
                "read_bandwidth": {"value": 64.0}, "write_bandwidth": {},
                "counter_samples": {"value": [{
                    "pmu": "uncore_imc_0", "event": "cas_count_read",
                    "instance": "CPU0", "direction": "read", "quality": "fresh",
                    "count": 1, "runtime_ns": 1_000_000_000,
                    "running_percent": 100, "bytes_per_second": 64.0}]}}}},
    }


class BandwidthContractTests(unittest.TestCase):
    def test_real_measurement_shapes(self):
        document = measurement()
        validate(document, "memory-bandwidth")
        document["requested_pmu"] = "uncore_imc_0"
        document["result"]["entity"]["metrics"]["measurement_scope"]["value"] = "controller_pmu"
        validate(document, "memory-bandwidth")

    def test_unavailable_and_discovery_shapes(self):
        document = measurement()
        document.update(mode="list", requested_pmu="list", pmus=[], pmus_truncated=False)
        document["result"].pop("entity")
        validate(document, "memory-bandwidth")
        document.update(platform="Windows", status="unavailable", reason="unsupported_on_this_platform")
        document["result"]["status"] = "unavailable"
        validate(document, "memory-bandwidth")

    def test_bad_records_and_aggregate_are_rejected(self):
        for field, value in (("bytes_per_second", -1), ("bytes_per_second", float("nan")),
                             ("bytes_per_second", True), ("runtime_ns", 0),
                             ("runtime_ns", float("inf")), ("count", -1),
                             ("running_percent", 101), ("quality", "unavailable"),
                             ("direction", "other")):
            with self.subTest(field=field, value=value):
                document = measurement()
                document["result"]["entity"]["metrics"]["counter_samples"]["value"][0][field] = value
                with self.assertRaises(AssertionError):
                    validate(document, "memory-bandwidth")
        document = measurement()
        document["result"]["entity"]["metrics"]["read_bandwidth"]["value"] = 128
        with self.assertRaises(AssertionError):
            validate(document, "memory-bandwidth")

    def test_bad_envelopes_are_rejected(self):
        for mutate in (
            lambda d: d.update(status="invented"),
            lambda d: d.update(captured_monotonic_ns=True),
            lambda d: d["result"].pop("entity"),
            lambda d: d.update(processes=[]),
            lambda d: d.update(platform="Darwin"),
            lambda d: d.update(requested_pmu="uncore_imc_0"),
        ):
            document = copy.deepcopy(measurement())
            mutate(document)
            with self.assertRaises(AssertionError):
                validate(document, "memory-bandwidth")


if __name__ == "__main__":
    unittest.main()
