# wtop Implementation Plan and Current Status

## 1. Positioning

wtop (WaterRun's top) is a modern Linux-only TUI performance workbench. Its goal is to put “what is happening now,” “why is it slow,” “which process or device is involved,” and “what can be done safely” into one responsive interface.

The current version is the `0.1.0-dev` development preview, not a completed 0.1 release. The first vertical slice—CPU/memory/PSI → Snapshot → ViewModel → responsive TUI → luainstaller—is operational. Current work focuses on features, hardware backends, and release evidence instead of presenting design documents as implemented behavior. CPU/GPU identity and telemetry are becoming substantially richer, but the project does not claim parity with CPU-Z, GPU-Z, AIDA64, or HWiNFO.

## 2. Status Definitions

- **Implemented**: runtime code and automated tests exist, and the feature executes on the current development host.
- **Partially implemented**: the basic path works, but UI, provider, permission, or platform coverage is incomplete.
- **Planned**: described by design, but not delivered by the current runtime.

“Implemented” does not imply validation across every distribution, kernel, terminal, or physical hardware configuration.

## 3. Original-Requirement Mapping

| Original requirement | Current status | Next-stage gap |
| --- | --- | --- |
| Attractive modern TUI | Custom cell grid/diff, five themes, color fallback, and responsive pages are implemented | Visual refinement, complete overlays, broader terminal matrix |
| Different window aspect ratios | tiny, narrow-tall, wide-short, wide-tall, and multiple PTY dimensions are covered | Continuous resize, tmux/SSH, more extreme dimensions |
| Customizable layout | Fixed widgets can move in four directions, adjust split ratios, undo/redo, and persist through schema v2 | Add/remove/replace widgets, drag-and-drop, import/export, recovery/backup |
| Multiple tabs | Eight fixed tabs—Overview, Processes, Compute, Storage & I/O, Network, GPU, Workloads, Insights—work | Add/remove/rename/reorder tabs and multiple workspaces |
| i18n | Safe YAML, built-in plural rules, formatter, generated registry, main-TUI messages, per-key fallback, and bounded XDG user-catalog loading are implemented | Technical-reason localization, pseudolocale, RTL |
| Stronger performance monitoring | CPU usage and identity/topology/cache, memory, PSI, disk, mounts, network/sockets, processes, CPUFreq, hwmon, powercap, cgroup v2, and DRM/sysfs GPU are implemented | NUMA, routes, systemd/container semantics, threads/PSS, cross-resource links |
| Deep inspection | Selectable SMART/NVMe, experimental `perf stat` RAM PMU sampling, and sshd Inspectors work | Unified resource navigation, complete session/event providers, PMU platform mapping and validation |
| GPU | DRM devices, PCI IDs/link metadata, AMD sysfs/DPM, Intel i915/xe frequencies, DRM fdinfo utilization/process tables, and hwmon temperature/power joins are implemented | Client/region drill-down, NVML, AMD SMI, Level Zero, MIG/tile |
| Performance release/actions | Diagnostics first; the TUI exposes only `SIGTERM` with PID identity revalidation | Define product scope before adding STOP/CONT, renice, or tuning protocols |
| Linux Only | The rockspec, Make/bootstrap, C compile gate, and unified CLI entry reject non-Linux platforms; the data layer is Linux-specific | Minimum kernel/distribution baseline |
| Lua | Business logic, collection, UI, configuration, and i18n use PUC Lua | Retain the Lua 5.4 syntax subset and Lua 5.5 release ABI |
| LuaRocks installation | Linux-only `scm-1` rockspec, isolated installation, and installed-CLI smoke paths exist | Versioned release rock |
| luainstaller | onedir/onefile, explicit locale inclusion, locked payload validation, and `make checksums` exist | Multi-architecture/libc, final-candidate rebuild, SBOM/signing |

## 4. Current Implementation Baseline

### 4.1 Runtime

- PUC Lua 5.5.1 is the release toolchain; LuaJIT is unsupported.
- Source avoids 5.5-only syntax, and pure-Lua unit tests also run under 5.4.
- The repository's `wtop_native.so` uses C17 and the Lua C API. It currently handles:
  - raw terminal, poll, resize/exit signals, and restoration;
  - monotonic/realtime clocks;
  - absolute-argv subprocesses, minimal environment, process-group cleanup, cancellation, timeout, and output limits;
  - Linux filesystem helpers, atomic writes, pidfd identity signaling, `wcwidth`, UID queries, and `execve`;
  - bounded nonblocking/no-follow regular-file reading: 4 MiB by default, explicit maximum 64 MiB, with final symlinks, devices, FIFOs, and oversized input rejected while regular-file-shaped procfs/sysfs pseudo-files remain supported.
- There are currently no runtime `luv`, third-party `terminal.lua`, or other LuaRock dependencies.
- Native builds default to `-O2 -g0`; the Makefile is also a module-target dependency, so build-rule changes trigger recompilation.
- The Scheduler uses single-threaded deadline scheduling. Process/CPUFreq/hwmon floors are 1000 ms, socket/cgroup floors 2000 ms, mount floors 5000 ms, and GPU floors 500 ms, with failed-task backoff. Inactive pages use slower background intervals.
- Resource-sensitive build/test entry points run a preflight guard that evaluates available memory, swap headroom, memory PSI, and load per CPU. Guarded Make validation targets are declared nonparallel; an unhealthy host is refused rather than adding pressure after an OOM event.

### 4.2 UI

- Tabs: Overview, Processes, Compute, Storage & I/O, Network, GPU, Workloads, Insights.
- Widgets: metric, sparkline, table, text, panel, tab/status bar.
- A virtual cell grid draws by display-column width; the diff renderer emits only changed runs.
- Keyboard, basic mouse, bracketed-paste decoding, resize, and terminal-capability fallback are supported.
- Current layout editing moves fixed widgets in four directions, adjusts split ratios, and stores up to 50 undo/redo steps per page. Widgets cannot be added, removed, or replaced.
- Responsive default geometry selects the richest available form for the actual rectangle. Compact windows first switch axes/reflow, then retain the focused or higher-priority branch only when space is still insufficient. Standard uses up to two columns, wide-short up to four, and wide-tall up to three. Actual placement drives both ViewModel and collector visibility: hidden tables are not modeled, and collectors unneeded by any visible widget fall back to background intervals.
- The process page provides text search, a fixed sort cycle, PPID tree, selected-item details, and confirmed `SIGTERM`. It is not yet a complete htop-style process browser.
- An elevated invocation is identified in status/diagnostic output. Direct `sudo wtop` and explicit `--sudo`/`--elevate` re-execution are supported without a resident root daemon.

### 4.3 Data

- CPU usage: `/proc/stat`, `/proc/loadavg`.
- CPU identity: `/proc/cpuinfo` plus bounded CPU topology/cache sysfs for vendor/model, architecture fields, packages, physical cores, logical threads, online/present/isolated sets, and cache inventory. Per-core implementer/part, capacity, kernel core type, maximum frequency, and SMT width form explicit heterogeneous core-type groups across x86, ARM, RISC-V, and other kernel-exposed architectures; repeated shared-cache CPU lists are parsed once.
- Memory: `/proc/meminfo`, `/proc/vmstat`.
- Pressure: `/proc/pressure/{cpu,memory,io}`.
- Disk: `/proc/diskstats` and block-size sysfs.
- Network: `/proc/net/dev` and `/sys/class/net`.
- Connections: `/proc/net/{tcp,tcp6,udp,udp6,unix}`. Bounded `/proc/<pid>/fd` owner scanning occurs only when the Network-page connection table has an actual placement.
- Processes: `/proc/<pid>/stat` and status; the detail interface can read cmdline/io/cgroup. The default collector limit is 8192 PIDs and the TUI-model limit 2048 rows.
- CPU frequency: cpufreq policy sysfs.
- Sensors: `/sys/class/hwmon`, including temperatures, fans, voltage, current, power, energy, thresholds, alarms, and faults. Known kernel/hardware sentinel values are filtered instead of being presented as plausible physical measurements.
- Power: powercap sysfs zone hierarchy, energy counters, direct power, and constraints. Energy deltas use monotonic timestamps and handle counter wrap/reset. CPU package/socket totals select one complete backend tree while retaining same-backend multi-socket roots; platform/`psys` selects one representative, and unknown or ambiguous roots remain unaggregated. Inaccessible energy files remain denied/unavailable rather than zero.
- Mounts: `/proc/self/mountinfo` and `statvfs`. Network filesystems, autofs, FUSE/`fuse.*`, fuseblk, and virtiofs skip potentially blocking statvfs by default, retaining mountinfo metadata and marking partial/estimated. Other native calls share a 50 ms admission budget, but a call already in progress cannot be preempted.
- Workloads: cgroup v2 files under `/sys/fs/cgroup`, to a default depth of 16 and at most 4096 nodes.
- GPU: `/sys/class/drm/card*`/render nodes, PCI identity and bounded local `pci.ids` names, PCIe/runtime metadata, AMD busy/VRAM/DPM, Intel i915/xe frequency, and DRM client counters in `/proc/<pid>/fdinfo`. A clearly sourced fdinfo aggregate can supply utilization where a hardware busy counter is absent. The collector records hwmon association keys but does not reread sensors; the ViewModel joins temperature/power through hwmon `class`/`device_target` and provides a GPU process table. Interactive fdinfo scanning occurs only when that table is actually placed; snapshots still force the full scan.

Outside the process model, connection, mount, workload, and GPU-process tables each model at most 512 rows. Collector-budget exhaustion sets `partial`/`truncated`; a UI-only row limit does not rewrite collector quality. Process/GPU-process and connection status provide total-count clues, while mounts/workloads currently lack a separate 512-row display-cap indicator. Insights has no foreground collector and uses existing background snapshots rather than resampling decorative process/GPU counts at 1 Hz.

Every collector returns status, quality, timestamp, duration, source, and reason. First counter samples, resets, device changes, invalid sensor sentinels, and missing values are never disguised as zero.

### 4.4 Inspectors and Actions

- SMART/NVMe enumerates at most 256 candidates under `/sys/class/block`, lets the user select one, and calls `smartctl --json=c --nocheck=standby --all` with a timeout, output limit, 60-second cache, masked serial, and validated device path. It does not currently use `smartctl --scan-open` or bridge-type detection.
- RAM-bandwidth Inspector formula v4 discovers matching PMUs and runs one approximately 250 ms system-wide sample through external `perf stat -a -A`/`sleep` for a limited set of data/CAS events. It calculates each controller instance using its own CSV runtime, chooses one Intel free-running/CAS substitute family, and deduplicates identical descriptor aliases. Missing instances/directions, partial events, or multiplexing yield estimated quality. Plain EINVAL/event-open failure yields unavailable, adding `permission_may_be_required` only when evidence such as `perf_event_paranoid` supports it; only explicit permission diagnostics yield denied. The startup probe does not execute `perf` or validate permissions. It has no CPU family/model mapping, multiplex correction, socket/channel split, or continuous chart. The theoretical-value API returns a value only when a caller supplies trusted rate/channel/bus-width inputs, which the default TUI does not.
- The sshd Inspector can combine systemd, process, and `/proc/net/tcp*` evidence. With no session/journal provider in the default application, those sections are explicitly unavailable.
- The TUI process action sends only `SIGTERM`: Lua revalidates PID/starttime, then native code holds a pidfd, revalidates again, and signals, closing the PID-reuse window.
- Privilege elevation applies to the entire invocation, not an individual Inspector. Re-execution uses a fixed system `sudo` path, the original process argv, and a sanitized environment, and occurs before raw-terminal entry.

### 4.5 Configuration, i18n, and Output

- `config.yml` uses configuration schema v1. `layout.yml` writes binary split-tree layout schema v2 and can read the linear-order v1. Both use restricted YAML profiles; layout writes are native and atomic.
- CLI/config themes are limited strictly to five exact built-in names. Locale tags are syntactically validated and normalized; a valid unknown tag can be provided by a TUI XDG user catalog instead of having to exist in the built-in list.
- Built-in locales are deterministically generated from YAML into Lua modules, and the registry uses literal `require`.
- `en-US` and `zh-CN` are stable. The initial eight additional languages are preview and fall back key by key.
- The CLI provides TUI, `--snapshot` JSON, `--agent` JSON, and `--diagnose`.
- The TUI loads bounded XDG custom-locale files at startup. `--snapshot`/`--diagnose` do not create a translator or scan that directory.
- JSON snapshots mask remote socket IPs by default and rebuild exported connection IDs from masked endpoints, preventing full remote addresses from leaking through internal IDs. Remote ports, local addresses, Unix socket paths, and interface MAC addresses remain unmasked. The Network-page TUI displays full endpoints and has no masking switch.
- Snapshot JSON exports `configuration.state` and optional `configuration.reason` without the internal `path`, allowing scripts to distinguish loaded/default/error/unavailable.
- Snapshot, diagnose, and agent output include bounded privilege identity metadata so callers can distinguish ordinary, direct-sudo, and explicitly elevated execution.
- The strict JSON decoder defaults to 4 MiB, depth 64, and 100000 value nodes with linear numeric scanning. The encoder replaces invalid UTF-8 in string values and object keys with U+FFFD.

### 4.6 Current Validation Entry Points

```bash
make check
make test
make test-54
make test-luarocks
make bundle-dir
make bundle-file
make test-bundle-dir
make checksums
```

`make test` currently contains 41 Lua 5.5 unit/fixture test files plus the responsive/color-depth real-PTY matrix; `make test-54` checks the pure-Lua 5.4-compatible subset. Hardware fixtures cover heterogeneous ARM, hybrid x86, RISC-V, large shared CPU-cache lists, powercap deltas/wrap/reset/constraints and overlapping `psys`, GPU PCI/fdinfo behavior, and invalid hwmon sentinels without requiring the development host to expose each device. Privilege and preflight tests cover CLI parsing, identity metadata, sanitized re-execution construction, cgroup v2 limits, and output integration without triggering an interactive password prompt.

Selected build and test Make targets run a lightweight resource precheck first and are kept nonparallel at the orchestration layer. The `build`, `test`, and `full` profiles inspect the tighter host/cgroup memory and Swap headroom, host/cgroup memory PSI, and load per CPU. An explicit environment override exists for deliberate operator use, but the normal path refuses to start resource-intensive work on an unhealthy host.

The default luainstaller `1.3.0-1` payload is locked by `tools/luainstaller-1.3.0.sha256`. An adjacent worktree is never selected automatically; an absolute `WTOP_LUAINSTALLER_ROCKSPEC` is the explicit development opt-in. `make checksums` covers only the two bundle executable entry points in `dist/SHA256SUMS`. Packaging evidence currently comes mainly from a Fedora glibc x86_64 development host, is not a formal release, and makes no minimum-glibc commitment.

## 5. 0.1 Release Goals

The following marks describe completion relative to a releasable 0.1:

- [x] Linux-only Lua 5.5.1 toolchain and native terminal restoration.
- [x] CPU usage/identity, memory, PSI, disk, mounts, network/sockets, basic processes, CPUFreq, hwmon, powercap, cgroup v2, and generic DRM collectors.
- [x] Responsive eight-tab frame, cell diff, themes, and basic mouse.
- [x] Configuration, layout schema v2 tree persistence (v1-compatible), JSON snapshot, and diagnose.
- [x] YAML i18n compilation, stable/preview catalogs, and per-key fallback.
- [x] onedir/onefile build targets.
- [x] Default luainstaller payload-hash validation and checksum target for both bundle entry points.
- [x] Linux-only LuaRocks installation, isolated-tree smoke test, and EUPL-1.2 repository license.
- [~] Processes page: text search, fixed sort cycle, PPID tree, detail overlay, and confirmed SIGTERM exist; threads, PSS/USS, combined filters, column management, and cross-resource navigation remain unfinished.
- [~] Layout editing: directional tree moves, ratio adjustment, undo/redo exist; add/remove/replace widgets, drag-and-drop, import/export, and backup/recovery remain unfinished.
- [~] Inspectors: three prototypes work; navigation, providers, and real-host coverage are insufficient.
- [~] GPU: DRM/sysfs/fdinfo, PCI naming/link metadata, a process-summary table, fdinfo utilization fallback, and hwmon temperature/power fill-in work; three vendor APIs, fan display, and client/frequency-domain/memory-region drill-down are not implemented.
- [~] Complete i18n: main TUI, headers, help, and Inspector labels are connected; raw provider field IDs/reasons, preview completeness, pseudolocale, and RTL remain unfinished.
- [x] Workloads/cgroup v2 page and collector base path.
- [x] CPUFreq, generic hwmon, powercap, and mount-capacity base paths.
- [~] GPU class/device_target sensor joins are implemented; broader device-topology joins, systemd/container semantics, and richer process data remain unfinished.
- [ ] Measured performance budgets and regression gates.
- [ ] glibc aarch64, minimum glibc/kernel, and planned musl release evidence.
- [ ] Real NVIDIA/AMD/Intel and no-GPU hardware matrix.

### 5.1 Safety Boundary

0.1 remains ordinary-user and read-only by default and introduces no resident root daemon. Direct sudo and explicit whole-process elevation are optional. Any process action must:

1. retain `(pid, starttime)` identity;
2. reread `/proc/<pid>/stat` before execution;
3. bind the original process with `pidfd_open`, revalidate starttime, and use `pidfd_send_signal`;
4. reject PID 1, wtop itself, and changed identity;
5. display the target and require explicit confirmation;
6. return per-target errors instead of presenting permission failure as success.

Whether 0.1 should expose SIGKILL, STOP/CONT, or renice requires separate UI, security, and test review. A low-level capability does not constitute a product promise.

## 6. Non-Goals

- macOS, Windows, or BSD.
- Clusters, remote agents, or a long-term metrics database.
- Automatic cache clearing, automatic process termination, or “one-click acceleration.”
- Destructive device management such as firmware updates or partition/filesystem repair.
- A mandatory privileged helper or resident root daemon.
- A stable third-party plugin ABI.
- Kubernetes orchestration-level views.
- A guarantee that every GPU/driver exposes the same metric set.

## 7. Roadmap

### Phase A: Stabilize the Development Preview

- Localize technical provider reasons and add pseudolocale and locale-layout tests.
- Add onefile PTY, clean-environment, and locale `--check` to standard CI.
- Add crash/signal/continuous-resize, tmux, and SSH scenarios.
- Establish repeatable performance benchmarks and calibrate CPU, RSS, first-frame, and input-latency budgets.
- Add explicit migration tools, backup, and clearer error recovery for configuration/layout; current behavior only reads layout v1 compatibly and rewrites v2.
- Add a privacy masking/export policy to the TUI connection table and define explicit JSON contracts for ports, local addresses, Unix socket paths, and MAC addresses.

### Phase B: Complete 0.1 Features

- Process combined filters, optional sort direction, threads/PSS/USS, namespaces, and complete detail navigation.
- Add/remove/replace widgets, drag-and-drop, layout import/export, and tab/workspace management.
- Add expand/collapse, details, systemd-unit, and container semantics to cgroup v2/Workloads.
- Extend the current GPU hwmon `class`/`device_target` join into broader CPUFreq, sensor, mount, and device-topology links, and define fan/rail/board-power semantics.
- Dynamic NVML, AMD SMI, and Level Zero providers with fake-library tests.
- Extend GPU process summaries into client/engine/memory-region drill-down and reverse navigation to host-process detail.
- Establish CPU family/model event allowlists, multiplex correction, per-socket/controller aggregation, and real-hardware error gates for RAM PMU; keep it experimental until then.
- Unify resource navigation for SMART, RAM-bandwidth, and service Inspectors.

### Phase C: 0.2

- Vendor semantics for multiple GPUs/MIG/tiles and richer GPU-process linkage.
- Deeper systemd units, containers, threads, PSS/USS, and process I/O.
- Throttle reasons, power-limit semantics, richer sensors, and insight rules.
- A second language wave and layout import/export.
- Stable glibc x86_64/aarch64 release matrix.

### Phase D: 0.3 and Later

- Metric recording and replay.
- Optional perf/eBPF backends, hot call stacks, and flame graphs.
- Cross-resource timeline correlation and alert rules.
- Extended EDAC/ECC, DIMM/NUMA, RAID/LVM/ZFS, and PCI/USB Inspectors.
- Evaluate an independent least-privilege tuning helper only after a clear user need and permission model exist.

## 8. Performance Goals

These remain unmeasured and uncalibrated release goals, not current results:

| Scenario | Goal |
| --- | --- |
| 1000 processes at default 1-second sampling | Average CPU below 2% of one core |
| Idle dashboard | RSS below 60 MiB |
| Input to display | p95 below 50 ms |
| First frame | Cold start below 500 ms |
| No data change | No full-screen redraw |
| Historical data | Fixed-size; never grows without bound over runtime |
| Collector failure | Back off one collector without blocking others |

The implementation already has fixed rings, diff output, collector durations, scheduler backoff, first-frame deferral for hidden sources, GPU fdinfo toggled by actual process-table placement, and pre-test resource health checks. In one safe-mode measurement on the current x86_64 development host, Overview probe plus initial active-page sampling took about 91 ms, and the first full fdinfo sample after switching to GPU took about 104 ms. These single-host values are not cross-machine release evidence; repeatable CPU/RSS/input-latency benchmarks are still needed.

## 9. 0.1 Release Gates

- Unit, fixture, PTY, clean-environment, onedir, and onefile tests pass after the resource precheck confirms sufficient headroom.
- `/proc` races, PID disappearance, counter resets, device hotplug, and permission errors do not terminate the application.
- Stable-locale coverage and placeholders are consistent; preview status is not misrepresented as stable translation.
- Every core visible string is internationalized; CJK and pseudolocale text do not break layout.
- No GPU, PSI, hwmon, systemd, or external helper still allows degraded startup.
- TUI/exported socket, session, device-identity, and process fields complete privacy review; masking contracts and explicit full-value choices are documented and tested.
- Experimental RAM PMU results are not presented as universally precise measurements; every claimed platform has event-formula, permission, multiplexing, and real-host comparison evidence.
- Native-module ABI, architecture, `ldd`, and minimum glibc/kernel baseline have reproducible evidence.
- glibc x86_64 and aarch64 targets each complete native builds and PTY smoke tests.
- Real performance budgets pass on the minimum and typical supported hosts.
- Release artifacts include checksums, an SBOM, third-party notices, and traceable build metadata.

## 10. Fixed Decisions and Open Questions

Fixed:

- Linux-only, PUC Lua 5.5.1 release ABI, and Lua 5.4 syntax subset.
- Custom cell grid/diff renderer and narrow C native terminal backend.
- Single-threaded deadline scheduler; no current `luv` introduction.
- YAML authoritative locales → deterministic Lua modules → literal registry.
- luainstaller builds onedir first, then onefile; each architecture/libc is built natively.
- EUPL-1.2 licensing.

Open decisions or missing evidence:

- Minimum Linux kernel, glibc, and distribution baseline.
- Formal-release SBOM, signing, and binary-redistribution records.
- Exact minimum GPU capability for 0.1—whether generic DRM is sufficient or a vendor API is required—and the real-hardware pool.
- Which profiling, process-management, or tuning capabilities “performance release” ultimately includes.
- Whether 0.1 accepts Workloads with raw cgroup v2 semantics only or first requires systemd/container identity, expand/collapse, and details.
- Whether to retain the experimental `perf stat` RAM-bandwidth Inspector in 0.1, including platform claims and default enablement.
- Maintainers, human review, and terminal-screenshot workflow for stable translations.
