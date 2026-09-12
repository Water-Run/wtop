# Current Architecture

This document describes the actual `0.1.0` structure. It does not present planned plugins, an Insight Engine, or vendor GPU providers as implemented capabilities.

## 1. Data Flow

```text
/proc · /sys · cgroup v2 · DRM
              │
              ▼
        bounded collectors ──────────────┐
              │                         │
              ▼                         │
 Snapshot + quality/capability     on-demand inspectors
              │                         │
              ├──── fixed history ring  │
              ▼                         ▼
         ViewModel                  text overlay
              │
              ▼
      8-page Workspace + widgets
              │
              ▼
      virtual cell grid → diff renderer → terminal
```

The default continuous collection path requires no external CLI. `smartctl`, `perf`, `sleep`, and `systemctl` are used only by on-demand Inspectors and are launched through the constrained Runner. There is currently no NVML, AMD SMI, Level Zero, or other vendor GPU library/provider.

UI state is currently coordinated directly by `tui.lua`, `workspace.lua`, and the process controller; it is not a complete Action → Reducer → single AppState architecture. The established boundaries still hold: collectors do not draw to the terminal, and widgets do not read procfs or sysfs directly.

## 2. Main Directories

```text
src/wtop.lua             CLI entry point
src/wtop/
  application.lua       configuration parsing and snapshot/TUI assembly
  tui.lua               event loop, keys, overlays, and runtime state
  workspace.lua         ten fixed pages, widgets, and layout editing
  view_model.lua        Snapshot-to-widget-model conversion
  engine.lua            collector scheduling, snapshot merging, and history
  core/                 clocks, scheduler, Runner, JSON, and other infrastructure
  linux/                procfs/sysfs readers and parsers
  collectors/           bounded continuous collectors
  inspectors/           SMART, RAM bandwidth, and sshd on-demand Inspectors
  model/                Snapshot, rings, and layout tree
  ui/
    backend/            native terminal interface adapter
    input/              keyboard, mouse, and escape-sequence decoding
    renderer/           cell grid, Unicode width, and ANSI diff
    layout/              responsive solver
    widgets/             metric, text, table, and other components
    views/               page frames
    theme/               semantic themes and terminal-capability fallback
  i18n/                  catalogs, restricted YAML, formatting, and plurals
  generated/locales/    generated built-in locale Lua modules
  config.lua             `config.yml` schema v1
  layout_store.lua       `layout.yml` schema v1/v2 reader and v2 writer
  actions.lua            process-identity revalidation and pidfd signal actions
native/wtop_native.c     libc-only Lua C module
locales/                 authoritative built-in `.yml` translation catalogs
tools/                   locale, toolchain, build, and checking tools
tests/                   unit/fixture and real-PTY smoke tests
```

The ten fixed pages, in order, are `overview`, `processes`, `compute`, `memory`, `storage`, `network`, `gpu`, `workloads`, `system`, and `insights`. Pages and widgets cannot currently be created or deleted.

## 3. Runtime

### 3.1 Lua and the Native Module

- The release toolchain targets PUC Lua 5.5.1, not LuaJIT. Pure-Lua tests continue to cover the Lua 5.4-compatible subset.
- `wtop_native.so` must match the major.minor ABI of the Lua runtime that loads it.
- The interactive TUI requires Linux, the native module, and TTY stdin/stdout. Without a TTY, use `--snapshot` to emit JSON.

The native module currently provides raw/alternate-screen terminal lifecycle management, terminal dimensions, `poll(2)`, signals and resize handling, monotonic/realtime clocks, sleep, filesystem helpers, `statvfs`, `wcwidth`, atomic writes, a constrained argv Runner, identity queries, `execve`, and pidfd signaling. Native `readfile` uses nonblocking/no-follow open, accepts regular files only, defaults to 4 MiB with an explicit 64 MiB maximum, and rejects symlinks, devices, FIFOs, and oversized content; procfs/sysfs pseudo-files presented as regular files remain readable. The module contains no widgets, layouts, translations, collectors, or vendor GPU libraries.

### 3.2 Event Loop

The TUI uses a single-threaded scheduler; Lua UI state and collectors all run on the main thread. On each iteration, the event loop waits at most 100 ms for terminal input or the next sampling deadline. The UI is marked dirty only by input, resize, completed sampling, or explicit invalidation, after which the renderer emits only cell runs that changed from the previous frame. There is no fixed “10–15 FPS” promise.

A synchronous external Inspector may occupy the main thread within its timeout budget. There is currently no vendor-API worker pool or background Inspector queue.

## 4. Collectors and Snapshots

The Engine registers collectors in a fixed order, including:

```text
cpu, cpu_info, memory, pressure, disk, network, connections,
process, gpu, cpufreq, hwmon, powercap, mounts, cgroup
```

A collector returns an `ok|unavailable|denied|error` status and a `fresh|stale|gap|estimated|unavailable|denied|error` quality. The Scheduler catches exceptions, records duration, and exponentially backs off failures for up to 30 seconds. Counter-delta collectors represent first samples, wraps, resets, and disappearance as gaps or unavailable values instead of generating rate spikes.

The current Snapshot resource shape is:

```lua
Snapshot = {
  sequence = 42,
  timestamp_ns = 0,
  cpu = {},
  cpu_info = {},
  memory = {},
  pressure = {},
  disks = {},
  network = {},
  connections = {},
  processes = {},
  gpus = {},
  cpu_frequency = {},
  sensors = {},
  power = {},
  mounts = {},
  workloads = {},
  quality = {},
  collectors = {},
}
```

A successful result replaces its corresponding resource. On failure, the previous usable data is retained, but quality changes to stale, denied, unavailable, or gap rather than continuing to claim freshness.

### 4.1 High-Cardinality Scans

- The process collector enumerates basic `/proc` fields for at most 8192 PIDs by default. Only the process currently selected in the TUI triggers deeper reads such as command line, I/O, and cgroups. The process model retains at most 2048 rows.
- Connection-owner scanning follows process fd links only when the connection table on the Network page has an actual visible placement. Standard JSON snapshots do not perform owner scans.
- The GPU collector scans standard DRM fdinfo to build per-client/per-process data only when `gpu_process_table` on the GPU page has an actual visible placement. Merely opening the GPU page or Insights does not trigger it. Overview and background sampling collect only device summaries. The GPU page displays at most 512 process-level summaries, while full client/region detail remains in the snapshot/JSON model. Noninteractive snapshots explicitly perform the full scan.
- The cgroup collector has depth and node limits. It exposes raw cgroup v2 hierarchy and kernel statistics without interpreting systemd-unit or container semantics.

ViewModel row budgets for connections, mounts, workloads, and GPU processes are all 512. A collector that hits its limit marks the resource `partial`/`truncated`; a display-only limit does not rewrite collector quality. Process/GPU-process and connection status provide total-count clues, while mount and workload tables currently have no separate ViewModel-cap indicator. An object that is not displayed must therefore not be interpreted as nonexistent. The layout solver passes placements to the ViewModel, so hidden tables do not build high-cardinality row arrays.

See [MONITORING.md](MONITORING.md) for exact limits and privacy boundaries.

## 5. Scheduling and History

Without an `--interval` override, CPU defaults to 500 ms, mounts to 5000 ms, and most other collectors to 1000 ms; connections default to 2000 ms. To prevent rapid refresh from triggering expensive scans, the Engine also enforces these minimum foreground intervals:

| Collector | Minimum foreground interval |
| --- | ---: |
| GPU | 500 ms |
| process, cpufreq, hwmon | 1000 ms |
| connections, cgroup | 2000 ms |
| mounts | 5000 ms |

The TUI first solves the current page against the real terminal geometry, then computes the foreground collector set from surviving widgets. A table hidden by responsive layout therefore does not remain foreground merely because its tab is active. Collectors not needed by any visible component continue at lower frequency: CPU/PSI at 2 seconds, disk/network at 3 seconds, memory/process/GPU/cpufreq/hwmon at 5 seconds, connections/cgroup at 10 seconds, and mounts at 30 seconds. When a page is first selected, collectors that have never run and are not visible are deferred directly to their background deadline. Initial and manual refresh force only collectors needed by visible components. Invisible collectors do not stop completely, preserving limited overall trends. GPU device summaries may continue foreground or background sampling, but fdinfo process scans are enabled only by an actual GPU process-table placement. Insights has no foreground collector set; its counters read bounded background snapshots and do not create 1 Hz foreground process/GPU sampling.

History is not stored in “15-minute/5-minute” tiers. The Engine retains bounded, monotonically timestamped points for aggregate metrics such as CPU, memory, PSI, disk reads/writes, network receive/transmit, first-GPU utilization, average CPU frequency, maximum temperature, CPU power, and root-cgroup CPU. A value or gap is appended only when the corresponding source actually completes, preventing unrelated collectors from duplicating old points. The renderer buckets a fixed one-second-per-column window of at most 240 seconds. Higher update rates increase sample density within a column instead of shortening the horizontal time span. There are currently no per-core, per-device, or per-process history subscriptions.

## 6. GPU Data Boundary

The GPU collector uses only DRM, sysfs, procfs, and a bounded local `pci.ids` lookup:

- It builds device identity from card/render nodes, PCI/sysfs, driver links, and PCI names. PCI BDF is used as the stable ID when available; otherwise an estimated DRM/sysfs identifier is used.
- It supports AMD `gpu_busy_percent`, VRAM/visible VRAM/GTT, AMD DPM frequency, and Intel i915/xe sysfs frequency paths.
- It parses standard DRM fdinfo engine/cycle/memory counters for bounded per-client/per-process aggregation and can derive a device-utilization fallback when no hardware busy counter exists.
- It records PCI class, revision, correctly nested `pci.ids` subsystem names, boot-VGA, NUMA, PCIe link, runtime-PM, and modalias metadata when exposed.
- It discovers associated hwmon paths and stores `hwmon_refs`, but does not duplicate temperature, power, or fan reads inside the GPU collector.

The ViewModel joins the global hwmon snapshot through `hwmon_refs`, hwmon `class`, and normalized `device_target`. When several channels match, it takes the highest temperature and highest power rather than summing overlapping rails; a native GPU metric takes precedence. The GPU page also has a bounded process table. With no matching sensor, Temp/Power remains `—`, and fans are not yet shown in the GPU table. There are still no vendor UUIDs, NVML/AMD SMI/Level Zero providers, NVIDIA proprietary metrics, MIG, AMD `gpu_metrics`, or vendor actions.

## 7. Inspectors

Inspectors run only in response to a user key and do not participate in continuous sampling. The default registry contains exactly:

- `storage.smart`: selects a `/sys/class/block` device, then calls `smartctl`; cached for 60 seconds;
- `memory.bandwidth`: enumerates a limited set of PMU names and performs one experimental system-wide sample through external `perf stat`;
- `service.sshd`: combines `systemctl show`, the process snapshot, and `/proc/net/tcp*`.

Current Inspector output is a generic text overlay, not a complete unified entity UI. DIMM/EDAC, PCI/USB, RAID/LVM, service logs/sessions, and similar sources are not registered as default Inspectors. See [DEEP_INSPECTION.md](DEEP_INSPECTION.md) for exact capabilities and failure semantics.

## 8. Layout and State

Workspace stores a binary split tree for each page. A leaf references a fixed widget; a split has a `horizontal|vertical` axis, a ratio, a gap, and exactly two children. Edit mode supports selecting a leaf, moving it by direction, adjusting the nearest parent split ratio, and up to 50 undo/redo steps per page.

`$XDG_CONFIG_HOME/wtop/layout.yml` (or `~/.config/wtop/layout.yml`) can read the legacy schema v1 ordered list and the schema v2 split tree. Once a layout is edited in the TUI, an orderly event-loop exit through `q`, `Ctrl+C`, or a captured exit signal saves schema v2 atomically with mode `0600`. There is no recovery journal for crashes, `SIGKILL`, or power loss. Validation limits include 1 MiB, depth 32, 511 nodes, gap 0–16, `ratio_micros` 1–999999, known pages/widgets, and unique leaves. Missing fixed widgets are appended and missing pages use the default tree. Unknown fields reject the whole file and fall back to the default layout.

Do not confuse the layout version with primary configuration: `config.yml` still uses schema v1. See [UI.md](UI.md) for schemas and key bindings.

CLI/config theme values accept only five exact built-in names. An unknown CLI value is an immediate error; an unknown configuration value rejects the entire configuration, falls back, and reports an error. Locale tags are syntactically validated and normalized, but a valid unknown tag can become the active locale after the TUI loads an XDG user catalog. `--snapshot` and `--diagnose` do not create a translator or scan the user catalog directory.

## 9. Identity, Security, and Privacy

- Process actions use `(pid, starttime_ticks)` identity. Lua revalidates `/proc/<pid>/stat`; the native layer then holds a pidfd, revalidates again, and sends only allowlisted signals. The TUI's current `k` action sends only SIGTERM and requires confirmation.
- GPUs prefer PCI BDF. Identity quality is estimated when no BDF exists. There is currently no vendor UUID.
- External programs must use an absolute executable path and argv without shell concatenation. The Runner controls file descriptors, environment, process group, timeout, and output size.
- `--sudo`/`--elevate` re-executes the current invocation through a fixed system `sudo` path with a minimal sanitized environment; direct `sudo wtop` is also recognized. There is no resident privileged daemon or mutable shell-command helper.
- Layouts are atomically saved with mode `0600`; primary configuration is read-only.
- The Network page displays full endpoints, Unix paths, UIDs, and discovered owners. JSON snapshots mask remote IP addresses by default, but not local addresses, ports, Unix paths, MAC addresses, or owners. See [MONITORING.md](MONITORING.md).
- Default JSON export rebuilds stable connection IDs from the masked remote endpoint so full addresses cannot leak through internal IDs. Only the explicit internal `include_remote_addresses=true` option preserves the original ID.
- The strict JSON decoder defaults to 4 MiB, depth 64, and 100000 value nodes, and scans numeric tokens linearly. The encoder replaces invalid UTF-8 in both string values and object keys with U+FFFD. This node budget is independent of the separate layout/YAML node limits.
- Snapshot export includes a `configuration` object containing only configuration `state` and optional `reason`; the internal configuration status `path` is not exported.
- `--safe-mode` substitutes a nonexecuting Runner, preventing an injected executor from bypassing policy. It does not disable ordinary procfs/sysfs reads.

The mount collector does not call synchronous `statvfs` by default for network filesystems, autofs, FUSE/`fuse.*`, `fuseblk`, or `virtiofs`, avoiding remote or userspace-daemon stalls in the single-threaded event loop. Other native statvfs calls share a 50 ms admission budget. Elapsed time is checked after each return and before the next call; once exhausted, remaining mounts are skipped. This is not a syscall timeout, and a call already in progress cannot be preempted, so it may still exceed 50 ms or block. Skipped mounts retain identity while capacity/inodes become unavailable or partial and overall quality becomes estimated. This is not evidence of zero capacity or an offline mount.

The program runs unprivileged by default and never installs a resident privileged helper. Elevation is explicit and applies to the current process invocation only.

## 10. Current Test Boundary

- The current 47 Lua unit/fixture test files cover platform gates, procfs, sysfs, connections, cgroup v2, DRM fdinfo, GPU frequency/hwmon joins, heterogeneous CPU inventory, powercap, SMART, PMU, layouts, i18n, input, renderer, Runner isolation, resource preflight, privilege handling, pidfd actions, JSON boundaries, export privacy, hardware-absent driver trees, offline inspector replay, process-collection scale limits, and the sudo file-access policy.
- PTY smoke tests cover `40×10`, `60×20`, `80×24/25`, `80×50`, `160×24`, `200×22`, `180×45`, resize, CJK, key paths, alternate-screen restoration, and layout persistence.
- onedir/onefile have post-build CLI, snapshot, and PTY targets.

Selected build and test entry points use nonparallel resource prechecks for available memory, swap headroom, memory PSI, and load per CPU. When the host is unhealthy, validation is refused rather than increasing pressure. This preflight is separate from hardware fixture coverage.

These tests are not a real-hardware matrix. Release evidence is still missing for multiple architectures/libcs/older kernels, real NVIDIA/AMD/Intel/no-GPU hosts, USB/SAS SMART bridges, and cross-platform PMU comparison. There is also no fixed-hardware long-term performance-regression baseline.
