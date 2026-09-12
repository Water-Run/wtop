# Deep Inspection: Current Implementation and Boundaries

This document describes only the current `0.1.0` implementation. wtop's long-term direction is to put commonly needed read-only diagnostic information in one TUI, but it is not currently a complete replacement for `smartctl`, `perf`, `systemctl`, `ss`, or vendor-specific GPU tools.

## 1. Current Entry Points

The default registry currently registers only three on-demand Inspectors:

| Key | Inspector | Current sources |
| --- | --- | --- |
| `s` | SMART / NVMe | `/sys/class/block` + optional `smartctl` |
| `b` | System RAM bandwidth | PMU sysfs descriptions + optional `perf stat`/`sleep` |
| `d` | `sshd` service and listening ports | optional `systemctl` + process snapshot + `/proc/net/tcp*` |

Results appear in a scrollable text overlay. The overlay supports arrow keys, `PageUp`/`PageDown`, `Home`/`End`, and the mouse wheel; close it with `Esc`, `Enter`, or `q`. The current renderer displays only section scalar values and quality line by line. Table values collapse to `[N items]`, and field unit/source/timestamp/reason details are not fully expanded. There is no generic entity browser, hierarchical detail navigation, field pinning to dashboards, Inspector history, or plugin UI; these remain future directions.

Every external helper is invoked through the shell-free argv Runner with timeout, output-size, fixed-environment, and process-cleanup constraints. `--safe-mode` disables the Runner, so the parts of these three Inspectors that depend on external commands become unavailable; ordinary procfs/sysfs collectors continue working.

## 2. SMART / NVMe

### 2.1 Device Selection

After `s` is pressed, wtop presents a selectable list of block devices instead of checking the “first disk” by default. The selector supports:

- `↑`/`↓`, `PageUp`/`PageDown`, `Home`/`End`, and the mouse wheel to move the selection;
- `Enter` to inspect the selected device;
- `Esc` or `q` to close.

Devices come from `/sys/class/block`, with a current limit of 256 entries. Partitions and virtual devices matching `loop*`, `ram*`, `zram*`, or `fd*` are filtered out. Remaining devices are sorted by name and mapped to `/dev/<name>`.

There is currently no `smartctl --scan-open`, USB/SAS bridge `-d` type detection, manually entered device path, or multipath deduplication. Some USB enclosures, RAID devices, device-mapper targets, or nonstandard block devices may therefore be absent or may require unsupported `smartctl` arguments.

### 2.2 Invocation and Data

For the selected device, wtop runs:

```text
smartctl --json=c --nocheck=standby --all /dev/<device>
```

The current policy uses a 2-second timeout, a 4 MiB output limit, and a 60-second result cache. `--nocheck=standby` avoids actively waking standby devices. wtop does not start SMART self-tests or perform firmware, repair, or write operations.

Fields currently parsed and directly displayable in scalar sections include:

- model, masked serial number, firmware, capacity, protocol, rotation speed, and inferred device kind;
- overall SMART passed state, temperature, power-on hours, power-cycle count, and the `smartctl` exit bitmask;
- NVMe critical warning, available spare, percentage used, data units, media errors, and unsafe shutdowns;
- ATA SMART attribute ID, name, normalized value, threshold, and raw value are included in the Inspector result, but the generic overlay currently displays the whole list only as `[N items]` and cannot browse individual entries.

Serial numbers longer than four characters retain only the last four characters by default, replacing the rest with `*`; shorter serial numbers are completely masked. Device-kind inference uses only protocol, rotation rate, or an explicit `SSHD` marker in model/product text. wtop does not invent a cross-vendor “health score.” It also has no dedicated view for SMART self-test history.

A missing `smartctl`, insufficient device permissions, timeout, truncated output, or invalid JSON is returned as unavailable, denied, or error; it is never interpreted as device health.

## 3. RAM Bandwidth (Experimental)

The current implementation is a one-shot system-wide estimate, not continuous RAM-bandwidth monitoring or a memory benchmark. Pressing `b` does the following:

1. Searches `/sys/bus/event_source/devices/` for PMUs whose names begin with `uncore_imc`, `amd_df`, `amd_l3`, `hisi_sccl`, `arm_dmc`, or `dmc`.
2. Selects a limited set of read/write events from each PMU's `events/` directory.
3. Runs one approximately 250 ms `perf stat -a -A` sample by absolute path, using `sleep` as the timed workload.
4. Converts each CPU/uncore-controller instance according to its own runtime in perf CSV, then sums the instance rates into system-wide read/write B/s.

Sampling is internally limited to 50–2000 ms; the TUI uses 250 ms by default. Runner timeout is the sample duration plus 1250 ms, and the default output limit is 512 KiB. PMU enumeration examines at most 256 devices and 512 sysfs events per device; one `perf` invocation uses at most 64 supported events. Default operation also requires executable `perf` and `sleep`. Reliable parsing requires runtime in `perf stat` CSV, available since perf 4.1; older formats safely return unavailable instead of estimating from wall-clock time. `perf_event_paranoid`, `CAP_PERFMON`, and kernel/platform event support also affect the result.

Only these event names or patterns are recognized:

- `data_read`, `data_write`;
- `cas_count_read`, `cas_count_write`;
- names containing `rdcas`/`wrcas` or `cas_count_rd`/`cas_count_wr`.

Unknown events are not guessed to be bandwidth events. When a host exposes both Intel free-running data events and substitute CAS families, one complete family is selected, preferring a complete free-running read/write family while retaining every PMU/socket instance in that family. This avoids counting the same DRAM traffic twice. sysfs event aliases with an identical encoding descriptor in the same PMU and direction are also counted only once. Byte units returned by `perf` are converted from the CSV unit; recognized unitless CAS/DRAM events are treated as 64 bytes per count. Every accepted count row must have a valid positive runtime. A missing or malformed runtime rejects that row instead of falling back to the requested sample duration.

If a valid subset remains, the result may succeed with `estimated` quality; if no valid supported count remains, inspection is unavailable. A missing read or write direction, partial supported events or instances, event-list truncation, multiplexing, or a missing running percentage also marks a successful result as `estimated`. A matching PMU only proves that a candidate hardware interface exists; it does not guarantee supported events or current-user permission. The startup capability probe does not run `perf`, so the inspection result after pressing `b` is authoritative. A result is classified `denied` only when output explicitly diagnoses a permission failure. Plain EINVAL/event-open failures cannot distinguish an unsupported event from a permission issue and are therefore `unavailable`, with a `permission_may_be_required` hint only when evidence such as `perf_event_paranoid` supports it. Successful default-TUI results report provider `perf_stat` and formula version `perf-stat-csv-no-aggr-v4`. The implementation invokes external `perf stat`, not `perf_event_open` directly. Bandwidth result fields use bytes/s, although the generic overlay currently displays raw values and quality without formatting or units.

Theoretical bandwidth is calculated only when the caller explicitly supplies a valid MT/s rate, an integer channel count, and an integer total bus width:

```text
MT/s × 1,000,000 × (bus_width_bits / 8) × channels
```

The default TUI does not provide these topology parameters and normally shows no theoretical limit or utilization. The implementation does not guess channel count and has no CPU family/model allowlist, per-socket/controller/channel breakdown, long-term history, or platform coverage comparable to vendor reference tools. `perf` CSV and event semantics can also change by kernel/platform, so this feature remains experimental.

## 4. `sshd` Service

Pressing `d`—or `Enter` on the Insights page—inspects the fixed `sshd.service`. The current implementation can combine:

- allowlisted fields from `systemctl show sshd.service`, such as ActiveState, MainPID, restart count, exit status, memory, CPU time, and cgroup;
- processes named `sshd` or `sshd:*` from the collected process snapshot;
- listening sockets in `/proc/net/tcp` and `/proc/net/tcp6`, using port 22 as a limited fallback when no configuration provider is available.

The current TUI does not inject effective sshd configuration, login sessions, socket owners, or journal/recent-event providers. Default operation therefore does not show effective configuration, active login origins, authentication failures, or recent logs; “unavailable” does not mean that no sessions or events exist. Non-systemd systems fall back to process and procfs-listener evidence only.

Processes, listeners, sessions, events, and configuration are table-valued sections. The generic overlay currently shows only the item count for each table and cannot browse listener addresses/ports or process detail. Scalar systemd-service fields are displayed directly.

The Inspector model can mask remote addresses when the caller supplies sessions, and the default TUI context enables masking: IPv4 retains only the first two octets and IPv6 only a short prefix. This policy applies only to the sshd Inspector. See [MONITORING.md](MONITORING.md) for privacy boundaries on the Network page and JSON export.

## 5. Capability, Permission, and Failure Semantics

- `available` means only that a basic source was detected; it does not guarantee a usable combination of device, permission, and event.
- `denied` means permission prevented access. wtop does not automatically elevate an Inspector in place.
- `unavailable` means a helper, PMU, device, event, or optional provider is absent.
- `error` means timeout, truncation, invalid structured output, or another execution failure.
- SMART has a 60-second cache. RAM PMU and sshd results are currently uncached and are not sampled continuously after the overlay closes.

The program runs as an ordinary user by default. A user may explicitly start the whole invocation through direct `sudo wtop` or `--sudo`/`--elevate`; there is no resident privileged helper and no Inspector action that modifies system state.

## 6. Release Validation and Remaining Work

Release validation should cover at least:

- SMART: multi-disk selection, no disks, list truncation, standby, insufficient permission, missing helper, and ATA/NVMe fixtures;
- RAM PMU: no PMU, no supported events, missing `perf`/`sleep`, permission denial, multiplexed or one-direction results, and numeric boundaries;
- sshd: systemd and non-systemd, default and custom ports, no process/listener, and missing log/session providers;
- selection, scrolling, and close paths at four PTY sizes;
- confirmation that external commands cannot execute under `--safe-mode`.

Long-term directions not yet implemented include a generic Resource Inspector, more entities/providers, SMART bridge parameters and self-test history, trusted platform PMU mappings, service session/log sources, and fuller per-field evidence and permission explanations.

## 7. References

- [smartctl JSON/YAML output option](https://www.smartmontools.org/static/doxygen/smartctl_8cpp_source.html)
- [Linux perf events security](https://docs.kernel.org/admin-guide/perf-security.html)
- [perf-stat manual](https://man7.org/linux/man-pages/man1/perf-stat.1.html)
