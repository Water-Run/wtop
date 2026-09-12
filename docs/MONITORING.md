# Monitoring Scope and Performance Operations

> This document separates the continuous collectors implemented in `0.1.0-dev` from later goals. A provider absent from “Current Implementation” must not be inferred to exist from a design goal.

## 1. Data-Source Principles

- Continuous sampling prefers Linux procfs, sysfs, cgroup, and DRM. External CLIs are reserved for on-demand Inspectors.
- Every collector probes capabilities first. Unsupported, denied, and error states must remain distinct from numeric zero.
- Rates for cumulative counters are calculated only from adjacent monotonic-time samples. First samples, resets, hotplug events, and sampling gaps are not filled with zeroes.
- High-cardinality scans have explicit limits and return partial/estimated results when a limit is reached or some paths are denied.
- External helpers run with absolute argv, a minimal environment, timeouts, cancellation, output limits, and process-group cleanup, never through a shell.

## 2. Current Collector Matrix

The CLI defaults to `--interval 1000`. The active page uses the greater of the base interval and the collector floor. Inactive pages continue lower-frequency sampling to preserve short histories.

| Resource | Current data | Primary source | Default foreground / background |
| --- | --- | --- | ---: |
| CPU | aggregate/per-logical-CPU utilization, load, context switches, interrupts, process counts | `/proc/stat`, `/proc/loadavg` | 1 s / 2 s |
| CPU identity | vendor/model/architecture, heterogeneous core types, capacity/max frequency/SMT width, packages/cores/threads, online/present/isolated CPUs, cache inventory | `/proc/cpuinfo`, CPU topology/cache/cpufreq sysfs | on demand / low-frequency |
| Memory | total/available/used, cache/slab/anonymous/dirty/writeback, shared, mapped, page tables, kernel stack, committed against the commit limit, hugepages, Swap, zswap, selected vmstat values, and a non-overlapping used/shared/buffers/cache/free partition for stacked display | `/proc/meminfo`, `/proc/vmstat` | 1 s / 5 s |
| PSI | CPU/memory/I/O `some`/`full` avg/total | `/proc/pressure/*` | 1 s / 2 s |
| Block devices | bytes/s, IOPS, busy, in-flight, queue size, estimated read/write latency, plus per-disk model/vendor/firmware, capacity, rotational medium, removable flag, active scheduler, queue depth and read-ahead | `/proc/diskstats`, block sysfs | 1 s / 3 s |
| Network interfaces | byte/packet/error/drop rates, operstate, MTU, MAC, carrier/duplex, speed when available, default-route family, and IPv4/IPv6 addresses with netmask, broadcast and peer | `/proc/net/dev`, `/sys/class/net`, `getifaddrs(3)` | 1 s / 3 s |
| Sockets | TCP/TCP6/UDP/UDP6/Unix endpoint, state, queue, UID, inode; PID/fd/name owner when available | `/proc/net/*`, `/proc/<pid>/fd` | 2 s / 10 s |
| Processes | `(pid,starttime)`, PPID, state, CPU, cumulative CPU ticks, RSS/VSZ, thread count, priority/nice/CPU, UID resolved to a local user name, and the full command line | `/proc/<pid>/stat`, `status`, `cmdline`, `/etc/passwd` | 1 s / 5 s |
| CPUFreq | policy/CPU set, current/min/max, driver, governor, boost/EPP | cpufreq sysfs | 1 s / 5 s |
| hwmon | temperature, fan RPM, voltage, current, power, energy, thresholds/alarms/faults; per-limit alarms such as `temp1_crit_alarm` are recognized alongside the bare `temp1_alarm` form, voltage channels are read from `in0` upward, and known invalid sentinel values are filtered | `/sys/class/hwmon` | 1 s / 5 s |
| Powercap | bounded zone hierarchy, energy/direct power, constraints, wrap/reset-safe deltas, separate CPU-package and platform/`psys` aggregates | powercap sysfs | 1 s / 5 s |
| Mounts | mount identity, filesystem/source/read-only state, plus capacity and inodes where safe | `/proc/self/mountinfo`, `statvfs` | 5 s / 30 s |
| cgroup v2 | CPU/max/weight, memory/Swap/events/limit, I/O rates, PIDs/events, PSI, cpuset | `/sys/fs/cgroup` | 2 s / 10 s |
| System identity | host name/domain/architecture, kernel type/release/build/command line, distribution from os-release, uptime and boot time, virtualization and container detection, SELinux/AppArmor/lockdown state, DMI machine/board/firmware (placeholder strings discarded; serial numbers, asset tags and the product UUID are never read), descriptor/PID/thread limits, entropy, kernel-wide counters, Swap devices, time zone | `/proc/sys/kernel`, `/proc/uptime`, `/proc/stat`, `/proc/swaps`, `/proc/vmstat`, `/etc/os-release`, `/sys/class/dmi/id` | 5 s / 30 s |
| Power supplies | battery status, charge and health against design capacity, energy or charge normalised to watt-hours, power draw, voltage, cycle count, remaining or to-full runtime, and mains adapter presence | `/sys/class/power_supply` | 5 s / 15 s |
| GPU | DRM device/node identity, PCI names/link metadata, selected AMD busy/VRAM, AMD/i915/xe frequencies, DRM fdinfo device/process data | `/sys/class/drm`, `/proc/<pid>/fdinfo`, bounded local `pci.ids` | 1 s / 5 s |

`--interval` accepts 100..10000 ms. The interactive TUI maps its initial value to the nearest of nine named steps: 8s, 5s, 3s, 2s, 1s, 0.75s, 0.5s, 0.3s, and 0.1s. Click the top-right control or press `f` to cycle at runtime. This never bypasses floors for expensive collectors: GPU 500 ms; process/CPUFreq/hwmon 1000 ms; sockets/cgroup 2000 ms; mounts 5000 ms.

History records the timestamp at which each source actually completes instead of duplicating old values when unrelated collectors finish. Each sparkline terminal column covers a fixed one second, up to 240 seconds total. A higher rate contributes more real points to each column and a lower rate creates sparse points, so switching rates does not change the horizontal time scale.

`/proc/<pid>/cmdline` is read during enumeration so every row can show a real
command name; `comm` from `/proc/<pid>/stat` is a fifteen-character truncation
and is only a fallback. `/proc/<pid>/io` and cgroup lists are still read on
demand only for the selected process, and the I/O columns are therefore
labelled as cumulative totals rather than rates. UID-to-name resolution reads
`/etc/passwd` directly rather than calling `getpwuid(3)`, because NSS can block
for seconds inside the render loop on a host configured for LDAP or SSSD. Interactive high-cardinality GPU fdinfo scanning is enabled only when `gpu_process_table` on the GPU page receives an actual placement after responsive solving. Merely switching to the GPU page, showing the GPU summary, or staying on Insights is insufficient. Overview/background GPU sampling still reads device summaries without enumerating `/proc/<pid>/fdinfo`. Noninteractive `--snapshot` retains the full scan.
Default inventory limits are 4096 DRM class entries, 32 cards, 64 render nodes, 16 hwmon references and 32 frequency domains per device. Process scanning is limited to 4096 processes, 1024 fdinfo entries per process, 32768 fdinfo files in total, 256 KiB per file, and 8192 clients. Hitting any limit marks the result partial/truncated instead of treating unscanned objects as absent.

The process collector scans at most 8192 PIDs by default. Native directory enumeration truncates to that budget plus a small non-PID allowance before sorting and per-PID reads. Results expose `process_candidates`, `process_limit`, `truncated`, and `partial`. Process search/sort runs over the collected set and the TUI model retains at most 2048 rows. Connection, mount, workload, and GPU-process ViewModels each build at most 512 rows; the GPU inventory separately has the 32-card collector limit. Connections, mounts, and GPU processes select a bounded priority subset, while workloads retain the first 512 collector-order rows. Collector truncation explicitly adds `partial`/`truncated` and some collectors also downgrade quality to estimated; a UI-only row limit does not rewrite collector quality. Process and GPU-process status show visible/total, and connection status shows the collector's total socket count. Mount and workload tables currently have no separate 512-row display-cap indicator. Available resource counts and scan state must therefore be considered; an undisplayed row does not prove that the object does not exist.

NUMA, routes/netlink, smaps/PSS, scheduler latency, and continuous RAM bandwidth are not yet in the continuous collector set. SMART, RAM bandwidth, and sshd are on-demand Inspectors; see [Deep Inspection](DEEP_INSPECTION.md).

The RAM-bandwidth Inspector is outside the scheduler matrix. A key press launches one approximately 250 ms system-wide external `perf stat`/`sleep` sample using a limited mapping of data/CAS event names. The matching-PMU probe does not run `perf` or validate permissions. Partial directions, partial events, or multiplexed results are marked estimated. The default TUI also lacks enough topology input to calculate theoretical utilization.

Insights is a static capability/Inspector-entry summary. It reads existing bounded background samples for counts, has no foreground collector set, and does not sample process or GPU data at 1 Hz merely for those numbers.

## 3. Socket Ownership and Privacy

- Owner scanning occurs only when the connection table on the Network page has an actual visible placement. It is limited to 1024 processes, 512 fds per process, 16384 symlinks total, and 8 owners per socket. Permission denials, PID/fd races, and limits reduce owner quality to partial/estimated rather than inventing missing owners.
- Owner scanning stops after leaving the Network page; lower-frequency socket-table sampling continues. Standard `--snapshot` also leaves owner scanning disabled.
- The TUI displays complete local/remote endpoints, Unix socket paths, UIDs, and visible owners. There is currently no TUI masking switch, so screen-sharing risk must be assessed manually.
- JSON snapshots replace the final octet of remote IPv4 addresses with `x` and retain only the first two groups of longer IPv6 addresses by default. Exported connection IDs are stably rebuilt from the masked remote endpoint, local endpoint, state, and related fields, so they do not retain an internal ID containing the full remote address. This masker does not alter remote ports, local addresses, Unix paths, interface MAC addresses, or existing owner fields. The CLI currently has no switch for exporting full remote IPs. Only the internal export API's explicit `include_remote_addresses=true` preserves both the full remote address and original ID.

Collectors and the Snapshot model retain full remote addresses internally; masking occurs at the JSON export boundary. This is not a privacy model in which the complete address never enters process memory.

## 4. Current GPU Capabilities

### 4.1 Implemented

- Enumerates `card*` and `renderD*` under `/sys/class/drm`, preferring PCI BDF as the stable ID and recording vendor/device ID, bounded local `pci.ids` vendor/model names, driver, DRM nodes, and mapping quality.
- Records PCI class, revision, subsystem IDs and nested `pci.ids` subsystem names, boot-VGA state, NUMA node, current/maximum PCIe speed and width, runtime PM, and modalias where exposed.
- Reads driver-exposed `gpu_busy_percent`, `mem_busy_percent`, VRAM/visible-VRAM/GTT values. These paths are mostly provided by amdgpu; absent paths remain unavailable.
- Supports AMD `pp_dpm_sclk`/`pp_dpm_mclk`, Intel i915 GT/legacy, and xe tile/GT/freq sysfs frequency domains.
- Parses standard DRM fdinfo client ID/name, engine ns/cycles/capacity, frequency, and memory total/shared/resident/active/purgeable; revalidates `(pid,starttime)` before process aggregation. When no hardware busy counter exists, bounded fdinfo engine data can provide an explicitly sourced device-utilization fallback.
- Displays a bounded GPU-page process table sorted by utilization, containing GPU, PID, name, aggregate utilization, memory, up to four busiest engines, and quality. A process using several GPUs gets one row per device. At most 512 rows are displayed, with visible/total and scan quality reported.
- Bounds the compute-page sensor table to 512 rows with alarm/fault rows ranked first, avoiding an all-row sort on unusually large hwmon inventories.
- The ViewModel joins general sensors through GPU `hwmon_refs`, hwmon `class`, and parsed `device_target`, placing the highest matching channel temperature and power into the GPU device table. The maximum avoids summing overlapping whole-board and rail values; a metric native to the GPU takes priority.
- Emits a `dev.waterrun.wtop.gpu/v2` snapshot model containing capabilities, quality, process-scan state, and truncation markers.

### 4.2 Not Implemented or Not Connected

- The GPU collector enumerates association keys under `device/hwmon/hwmon*` but does not reread temperature, power, or fans. Temperature/power comes from the general hwmon snapshot through the ViewModel. Without a matching `class`/`device_target`, relevant channel, or readable hwmon source, the column remains `—`. Fans are not shown in the GPU table.
- The TUI shows process-level summaries only. It has no interactive drill-down for DRM clients, frequency domains, individual memory regions, or GPU-to-host-process details; the complete model remains available in JSON.
- There is no NVML, AMD SMI, Level Zero Sysman, `nvidia-smi`, `amd-smi`, or `intel_gpu_top` provider, and distributions do not link these libraries.
- There are no NVIDIA proprietary utilization/VRAM metrics, MIG, AMD `gpu_metrics`, throttle reasons, ECC, NVLink, power-limit controls, or complete multi-tile semantics. Generic PCIe link metadata is read from sysfs when available.
- DRM fdinfo capability depends on kernel and driver. Hidden fdinfo, missing client ID/BDF, counter reset, or scan limits can produce only estimated/partial data; identical metrics are not guaranteed across all GPUs.

## 5. Process Model

The unique process identity is `(pid, /proc/<pid>/stat.starttime)`. A process may disappear between any two reads. After supplemental status/cmdline/io/cgroup fields are collected, `stat` is read again to validate the generation; samples that combine data from a reused PID are discarded.

The base scan reads `stat` and `status` for each process. cmdline, I/O, and cgroups are read on demand only for the selected process. There is no smaps/PSS/USS, thread row, namespace, environment, or fd detail. Environment variables are not read by default to avoid exposing secrets accidentally.

Process search is a case-insensitive substring match over PID, name, command, user, and state. The tree is based only on host-visible PPID. I/O sort keys exist, but unselected processes normally lack I/O fields, so this is not a complete `iotop` replacement.

## 6. Mount Capacity and Blocking Boundary

The mount collector always parses `/proc/self/mountinfo`. The default native provider skips `statvfs` for network filesystems, `autofs`, `fuse`, `fuse.*`, `fuseblk`, and `virtiofs`, because these synchronous calls may wait for a remote or userspace daemon and block the single-threaded TUI. Mount identity, source, type, read-only state, and other metadata remain available. Capacity/inodes become unavailable, the mount is partial, overall quality is estimated, and `statvfs_skipped_potentially_blocking_filesystem` is recorded. This does not mean that the filesystem is offline or has zero capacity.

Other native `statvfs` calls share a 50 ms cumulative admission budget. The collector checks time before a call and after the previous call returns. Once the budget is exhausted, it makes no further calls and records `budget_exhausted`, `statvfs_budget_ms=50`, and `statvfs_skipped_budget_exhausted`. The budget is not a thread or syscall timeout: a call already started cannot be preempted and may exceed 50 ms or block. Injected providers used by tests/embedders do not receive the budget by default; it applies only when `statvfs_budget_ms` is supplied explicitly.

## 7. Workloads / cgroup v2

The collector performs a breadth-first traversal under `/sys/fs/cgroup`, to a default depth of 16 and at most 4096 nodes. It skips symlinks, dot/unsafe names, and nondirectory entries. Each node reads a fixed set of cgroup v2 files and calculates deltas for CPU, I/O, memory/PID events, and PSI totals.

An inaccessible subtree may remain as a partial node. Missing controller files are node issues, not values disguised as zero. The page displays a flat path-indented list and currently has no expand/collapse, selected-item detail, systemd-unit, container/runtime identity, or namespace view.

## 8. PSI, Insights, and Actions

PSI is displayed as a metric, but the Insights page has no automatic rule engine, bottleneck inference, anomaly timeline, or automatic explanation of “high utilization versus actual pressure.” It currently shows only collector/Inspector capability summaries. Process/GPU counts come from background snapshots without registering foreground 1 Hz process/GPU sampling.

The only visible system action is a confirmed `SIGTERM` for the selected process. Lua first revalidates `(pid,starttime)`, then the native layer binds the target with a pidfd, validates identity again, and sends the signal. PID 1, wtop itself, and reused PIDs are rejected. There is no SIGKILL, STOP/CONT, renice, affinity, governor, power-limit, `drop_caches`, or automatic tuning action.

Collection runs as an ordinary user by default. Direct `sudo wtop` and explicit `--sudo`/`--elevate` re-execute the complete invocation before terminal raw mode, using a fixed system sudo path and sanitized environment rather than a shell command. Snapshot, diagnose, and agent output expose bounded privilege identity metadata. There is no resident privileged daemon, and elevation does not turn unavailable hardware into a zero-valued metric.

## 9. Data Quality

| State | Meaning |
| --- | --- |
| `fresh` | The current sample is usable |
| `stale` | A retained value exceeded its freshness deadline |
| `gap` | First sample, time gap, cumulative-counter reset, or an uncomputable delta; the specific reset reason may be recorded on the resource |
| `estimated` | An estimate or incomplete mapping was used |
| `unavailable` | The platform/driver lacks the capability |
| `denied` | The capability may exist, but current permission is insufficient |
| `error` | A read or parse failed |

`partial`/`truncated` are generally boolean markers on a resource or scan report, not top-level Engine quality values. Not every collector uses exactly the same quality subset. UI/JSON consumers must preserve quality, these markers, and reason together. Some technical reasons visible in the TUI remain untranslated.

## 10. Future Monitoring Capabilities

- NVML, AMD SMI, Level Zero, and a real-hardware capability matrix; richer GPU sensor semantics and client/region drill-down.
- systemd-unit/container semantics, expandable Workloads details, and cgroup/process cross-linking.
- NUMA, throttle reasons, frequency residency, scheduler latency, PSS/USS, and thread/namespace detail.
- Routes, addresses, and connection filtering; configurable and reviewed privacy masking for TUI/JSON.
- Metric recording/replay, evidence-based insight rules, and optional perf/eBPF backends.

## 11. JSON and Native-Read Safety Budgets

- The strict JSON decoder defaults to a 4 MiB input limit, depth 64, and 100000 value nodes; arrays, objects, and scalars each consume one node. It copies only the current numeric token, keeping parse work linear in input size. An invalid `max_nodes` option is rejected, and overflow returns `maximum_nodes_exceeded`.
- When the JSON encoder encounters invalid UTF-8 in a string value or object key, it stably replaces each invalid byte with U+FFFD before JSON escaping, preventing invalid UTF-8 JSON output.
- Native `readfile` defaults to 4 MiB and accepts explicit budgets only from 1 through 64 MiB. It opens with `O_NONBLOCK|O_NOFOLLOW`, confirms a regular file with `fstat`, and reads one extra byte to detect overflow. Final symlinks, devices, FIFOs, and over-budget input are rejected. procfs/sysfs pseudo-files presented as regular files remain supported. The pure-Lua data layer retains a fallback for tests/degraded operation, but the interactive TUI itself requires the native module.

## 12. Reference Interfaces

- [Linux procfs](https://docs.kernel.org/filesystems/proc.html)
- [Pressure Stall Information](https://docs.kernel.org/accounting/psi.html)
- [DRM client usage stats](https://docs.kernel.org/gpu/drm-usage-stats.html)
- [AMDGPU sysfs](https://docs.kernel.org/gpu/amdgpu/thermal.html)
- [Linux power capping framework](https://docs.kernel.org/power/powercap/powercap.html)
