# Agent / LLM Interface

`wtop --agent` emits one bounded system-status report for automation and LLM agents. It does not require a TTY, emit ANSI sequences, or mix logs into its output; stdout contains exactly one line of UTF-8 JSON.

```bash
wtop --agent
```

The top-level schema is `dev.waterrun.wtop.agent/v1`. Agents should first check `schema` for an exact match and reject unknown major versions. Unknown fields added within the same major version should be ignored.
The machine-readable JSON Schema is [agent-v1.schema.json](agent-v1.schema.json). It uses JSON Schema Draft 2020-12 and remains open to backward-compatible field additions.

## Data Structure

| Field | Meaning |
| --- | --- |
| `overall` | `ok`, `warning`, `critical`, or `unknown`, plus signal counts |
| `metrics` (object) | Compact raw values for CPU identity/core types/topology, memory, PSI, storage, network, GPU, separate CPU/platform power, sensors, and processes |
| `signals` (array) | Anomaly clues produced by deterministic thresholds, sorted by severity; these are not automatic diagnostic conclusions |
| `top` (object) | Bounded summaries of processes, block devices, interfaces, workloads, GPUs, and hottest valid sensors |
| `data_quality` (array) | Each collector's resource, freshness, status, and reason; always inspect this first when explaining missing values |
| `unavailable_sources` (array) | Data sources unsupported or inaccessible on the current host |
| `privacy` (object) | Categories of information intentionally omitted from the report |
| `privilege` (object) | Effective identity and whether this is an ordinary, direct-sudo, or explicitly elevated invocation |

Values retain machine units: capacities and rates use bytes and bytes per second, latency uses milliseconds, power uses watts, and utilization and PSI use percent. `metrics.power.total_watts` is emitted only for a complete selected CPU-package/socket backend; one separately selected platform/`psys` representative is reported as `platform_watts`. Unknown roots and ambiguous CPU backends remain unaggregated. Missing data is represented by an absent field or JSON `null`; it must not be treated as zero. Invalid hardware sentinel readings are filtered before export rather than emitted as extreme physical measurements.

Each `signals` entry uses stable `resource`, `code`, `severity`, `value`, and `unit` fields; `message` is display-only. Current thresholds are conservative hints, such as CPU at 75/90%, memory at 85/95%, device busy at 80/95%, and PSI `some avg10` at 5/20%. Agents should account for duration, workload characteristics, and `data_quality` before drawing conclusions.

## Full Snapshot

Use the following command when raw detail is required:

```bash
wtop --snapshot
```

It returns `dev.waterrun.wtop.snapshot/v1`, with additional collector fields
and longer lists. Beyond the resources `--agent` summarises, the snapshot also
carries `system` (host name, kernel, distribution, firmware, virtualization,
security modules, kernel limits and counters, Swap devices, time zone) and
`power_supplies` (batteries with charge, health against design capacity and
remaining runtime, plus mains adapters). Network interfaces additionally carry
their IPv4/IPv6 `addresses` and raw `counters`.

`system.firmware` deliberately omits serial numbers, asset tags and the product
UUID: the collector never reads them, so a snapshot pasted into a bug report
does not leak more host identity than the operator expects.

Call `--agent` first, then obtain a full snapshot only when an anomaly needs
deeper investigation, to avoid consuming context unnecessarily.

## Privacy and Invocation Contract

- Agent reports omit process command lines; they include only PID, name, state, user, and resource usage.
- Agent reports omit socket endpoints; full snapshots mask remote IP addresses by default as well.
- An `unavailable` entry does not imply a system fault. Optional hardware and missing permissions are reported separately.
- Process, device, and workload lists are bounded. An object absent from a Top list is not necessarily absent from the host.
- Running `sudo wtop --agent` or using explicit `--sudo`/`--elevate` can expose permission-gated sources. Consumers should inspect `privilege` and still use `data_quality`; elevated execution does not guarantee that every source exists or succeeds.
- Each invocation samples twice to calculate rates and normally takes about 250 ms. Callers that need continuous monitoring should poll only as needed, identify samples through `captured_unix_ns` and `sequence`, and avoid unbounded high-frequency calls.
- On success, the exit code is `0` and stdout contains exactly one newline-terminated JSON document. Diagnostics are written only to stderr. Callers must check both the exit code and schema and must not parse truncated output.

Example:

```bash
context="$(wtop --agent)" || exit
printf '%s\n' "$context" | jq '.overall, .signals, .top.processes'
```
