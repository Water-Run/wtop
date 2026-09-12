# Changelog

All notable changes to wtop are recorded here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); until 1.0.0 the
minor version may carry breaking changes to the JSON contracts, the layout
file format, and the configuration schema.

## 0.1.0 — 2026-09-13

First tagged release. Everything below is new; there is no prior version to
diff against.

### Observability

- Sixteen continuous collectors over procfs and sysfs: CPU utilization and
  identity, memory, PSI pressure, block devices, mounts, network interfaces,
  socket tables, processes, DRM GPUs, cpufreq, hwmon, RAPL powercap, cgroup v2,
  system identity, and power supplies.
- Every reading carries a quality state — `fresh`, `gap`, `partial`, `denied`,
  `unavailable`, `truncated`, `estimated` — so a missing sensor is visibly
  missing rather than silently rendered as zero. Collectors that fail back off
  exponentially instead of retrying every tick.
- On-demand inspectors for SMART (`smartctl`), memory bandwidth
  (`perf stat`), and service state, each degrading to a stated reason when the
  tool is absent, refused, or times out.

### Interface

- Ten tabs (Overview, Processes, Compute, Memory, Storage, Network, GPU,
  Workloads, System, Insights) over a responsive binary-split layout tree that
  persists across runs, with a differential cell renderer.
- Process table with tree view, multi-term search, eleven sort keys, signal
  delivery through `pidfd`, and per-process detail.
- Four color profiles (truecolor, 256-color, 16-color, no-color) and an ASCII
  fallback, selected from terminal capabilities.
- Ten languages at 431 message keys each, aligned by display width rather than
  byte count so CJK and emoji do not break table columns.

### Interfaces and packaging

- `--snapshot` and `--agent` JSON output over explicit field allow-lists,
  `--diagnose` capability reporting, and `--export`.
- LuaRocks rockspec, and luainstaller onedir and onefile bundles.

### Safety

- All terminal-bound text passes through control-byte sanitization, so a
  process name containing escape sequences cannot drive the terminal.
- Host-identifying DMI fields (serial numbers, asset tags, product UUID) are
  never collected or exported, and kernel command-line parameters that name a
  secret or identify the machine (`root`, `cryptdevice`, `rd.luks.key`,
  `systemd.machine_id`, and similar) are redacted before display or export.
- `/etc/passwd` and `/etc/group` are parsed directly rather than through NSS,
  because an LDAP or SSSD backend can block inside the render loop.
- A `sudo` session ignores the invoking user's configuration file, locale
  catalogs, and persisted layout, and never writes a root-owned file into that
  user's config directory.

### Verified against

This release was built and tested on:

- PUC Lua 5.5.1 and Lua 5.4 (compatibility subset); LuaJIT is not supported.
- Built and run on x86-64 with gcc 13.3, glibc 2.39, Linux 6.6. The CI matrix
  additionally builds with clang and on Ubuntu 22.04 on every push; that
  matrix has not yet reported on a released commit.
- 47 unit test files, a PTY harness with a VT screen model, a randomized input
  fuzzer, ASan and UBSan over the snapshot, agent, diagnose, and unit paths,
  and differential comparison of the data layer against `df`, `ss`,
  `/proc/diskstats`, `/proc/net/dev`, and `/proc/meminfo`.
- Hardware paths that this project's own machines do not have — GPU, battery,
  RAPL, hwmon alarms, SMART, `perf` — are covered by recorded fixtures of real
  driver output, not by live hardware.

### Known limitations

- Not yet run against real discrete GPUs, laptop batteries, or SMART-capable
  drives; those paths are fixture-tested only.
- Not yet built or run on ARM, musl, or distributions other than Ubuntu.
- Terminal behavior is verified through a PTY screen model, not against
  xterm, kitty, Alacritty, tmux, or an SSH session.
- The nine non-English catalogs have not had native-speaker review.
