# Cross-Platform Product Requirements

## Product Direction and Current Baseline

wtop's target is a modern, responsive system monitor that runs natively on Linux,
macOS, and Windows. Windows must monitor the Windows host itself. A native
32-bit x86 build and compatibility with Windows XP are implementation targets.
Windows Server 2008 is the available real-host Windows validation target; an XP
test environment is not available. Compatibility with older hardware and
classic Windows consoles running `cmd.exe`, including consoles without VT/ANSI
support, is a primary requirement.

Version 0.1.0 and its LuaRocks package remain Linux-only releases. The source
tree now includes development builds for macOS and Windows x86, with native
host collectors and shared Snapshot/TUI code. These builds have real-host
smoke evidence below; they have not been shipped as a cross-platform release.

## Required Behavior

1. **Native host monitoring.** On each of Linux, macOS, and Windows, the TUI
   shows CPU, memory, processes, storage, network, and basic system identity.
   `--snapshot`, `--agent`, and `--diagnose` work on the same host. The common
   Snapshot and quality contracts remain consistent across operating systems.
   Metrics with no equivalent source on an operating system report their actual
   availability; they must not appear as zero or as fresh data.
2. **Terminal adaptation.** The UI supports capable VT/ANSI terminals and a
   native Windows console path for consoles without VT/ANSI. It detects actual
   capabilities before enabling alternate screen, mouse input, paste modes,
   color, and Unicode glyphs. A keyboard-only, colorless ASCII presentation
   remains usable on a small console. Terminal input, resize, Ctrl+C, and
   normal/error exit restore the user's console state. A terminal that cannot
   process escape sequences must not display raw escape codes.
3. **Older-device behavior.** Collection and rendering remain bounded, avoid
   unnecessary work for hidden panels, and stay usable at the smallest layout
   sizes already supported by the UI. Performance targets and a minimum hardware
   baseline require measurements on the oldest supported machines.
4. **Platform-specific controls.** Process identity, process actions, privilege
   behavior, configuration paths, and optional inspectors use platform-specific
   implementations. An action is exposed only where the platform can enforce
   its safety checks and report failures accurately.
5. **Native delivery.** Each supported operating system has a build and
   distribution path that can start the TUI and structured-output commands on
   that system. Windows XP compatibility is a code and build target; without an
   XP runtime test, it remains unverified and must not be presented as a tested
   release guarantee.

## Implementation Boundaries

- Keep Snapshot, ViewModel, widgets, layout, and the backend-neutral cell diff
  shared. Select the host collector and native-service implementations by
  operating system; keep Linux `/proc` and `/sys` readers in the Linux backend.
- The terminal backend keeps `start`, `size`, `poll`, `present`, `capabilities`,
  and `stop`. Native Win32 console sessions use screen-buffer APIs and native
  key events; ANSI streams use the shared encoder. The Cygwin/OpenSSH launcher
  sets its PTY to raw mode while the program runs.
- Hardware sources beyond the core resources are native per platform.
  Windows enumerates display adapters through SetupAPI and joins DXGI 1.1 for
  the adapter LUID that keys the PDH GPU counters; processor frequency,
  ACPI thermal zones, and GPU load come from PDH counters with English names;
  batteries from `GetSystemPowerStatus`; workloads are running services
  grouped by host process. macOS reads IOAccelerator statistics, HID
  temperature services, SMC fan and power keys, IOReport energy and
  performance-state residency, IOPowerSources, per-process socket
  descriptors, and resource coalitions. IOReport, IOHID events, the SMC and
  the coalition query have no SDK header, so each is resolved at run time and
  a missing one reports its source as unavailable.
- Linux opens NVML (`libnvidia-ml.so.1`) with `dlopen` when present and joins
  it onto DRM devices by PCI address; safe mode does not load it.
- The Windows x86 artifact bundles a matching 32-bit Lua runtime and native
  module. It is built with an XP target macro and PE32 i386 format. Newer API
  calls needed for version, architecture, and uptime are resolved dynamically;
  CPU counters have a dynamically selected pre-SP1 fallback. This is build and
  API evidence, not an XP runtime result.

## Validation Matrix

| Runtime host | Terminal case | Acceptance focus |
| --- | --- | --- |
| Linux x86_64 | Fedora 44 development host | 50 Lua test files, the Lua 5.4 subset, and the PTY matrix; Snapshot with DRM/fdinfo GPU data; NVML reported unavailable without the NVIDIA driver |
| Linux aarch64 | Ubuntu 24.04, DGX Spark (Cortex-X925/A725, NVIDIA GB10, driver 580), SSH | Native build and the 50 Lua test files; NVML joined onto the DRM node: utilization, clocks, temperature, power, UUID, driver version, per-process GPU memory |
| Linux | Debian 13 x86_64 SSH PTY | Snapshot, Agent, diagnose, TUI quit (earlier run) |
| macOS | macOS 26.5 arm64 (M4) SSH PTY | CPU with per-core user/system/nice, P/E cluster frequency from performance-state residency, memory, processes, IOKit disk I/O with estimated busy time, 64-bit interface counters, sockets with owners, GPU utilization, clock and memory, HID temperatures, SMC fan and system power, IOReport CPU/GPU/ANE/DRAM energy, coalition workloads, load average; Snapshot and TUI |
| Windows XP, 32-bit x86 | No test environment available | PE32 i386 build; every import of the native DLL is present on XP (reviewed with objdump); runtime remains unverified |
| Windows Server 2008 | 6.0.6003 x86_64 host running the x86 artifact | Native resources including per-core CPU utilization and time classes, CPU identity and caches, memory composition, physical-disk I/O, sockets with owning processes, the display adapter with driver version and memory through SetupAPI, power-plan and rated CPU frequency, service-host workloads, Snapshot, Agent, diagnose, configuration/layout I/O, and Cygwin/OpenSSH PTY TUI including hang-up exit |
| Newer Windows | 10.0.26100 x86_64 host running the x86 artifact | The same resources as Server 2008 with 64-bit interface counters, effective CPU frequency including turbo, an ACPI thermal zone, 64-bit process memory read from a 32-bit build, Snapshot, Agent, diagnose, and native Win32 console TUI through PowerShell/OpenSSH ConPTY |
| Server 2008 classic CMD | Legacy console with code page 936, driven by `tools/console_harness.c` | Screen-buffer drawing, Chinese text in double-byte cells, key events, page switching, the terminate menu, buffer resize, `q` and Ctrl+C exit with the console restored |
| Windows with WSL | Linux runtime in WSL | Linux compatibility; this does not establish native Windows support |

The Server 2008 SSH session runs through a Cygwin pipe. To exercise the
legacy console itself, `tools/console_harness.c` allocates a real console on
that host, starts wtop on it, then reads the screen buffer and injects key
and resize events. That checks what the console holds, not how a physical
monitor and font render it; a person at the machine is still the final check. The newer Windows ConPTY run exercises the Win32 console
backend, but does not establish old CMD display quality. XP cannot receive a
runtime-tested claim without an XP test environment. macOS deployment targets
are 11.0 for arm64 and 10.13 for x86_64; only arm64 macOS 26.5 has been run.

On 2026-09-28, the current x86 development bundle ran `--snapshot` on the
Server 2008 host. C: and D: returned complete capacity. WMI reported D: as a
removable drive. In three direct native mount samples, D: was pending on the
first call and fresh one second later; C: stayed fresh. This exercises the
background probe with working media. Empty or slow media, hotplug, and mapped
network drives remain untested with this build.

In a separate back-to-back native call sample on that host, discarding each
collector's first call, the median of eight calls was 2.56 ms for processes,
0.01 ms for GPU, 0.74 ms for disks, and 0.04 ms for mounts. This measures warm
collector calls only; it does not include periodic rescans or TUI CPU usage.

The classic-console harness now measures child CPU time over a chosen window.
On this Server 2008 host, the current bundle used 1.71–1.87% of one core on
Overview, 3.43–4.05% on Processes, and 1.71% on GPU across repeated 10-second
windows after a two-second warm-up. The process exited normally. Before frame
coalescing and the printable-ASCII layout path, separate runs on the same host
used roughly 14%, 21%, and 7% on those pages. These short single-host runs do
not establish a release performance baseline.

## Development Builds

On macOS, run `./tools/build_macos.sh`; the executable bundle is
`dist/macos/wtop`. On Linux with a 32-bit MinGW cross compiler, run
`./tools/build_windows_x86.sh` and copy `dist/windows-x86` to Windows.
Run `wtop.cmd` from CMD or PowerShell. In a Cygwin/OpenSSH PTY, use
`wtop.sh` so keyboard input is delivered without line buffering. Both bundles
contain Lua 5.5.1 and their matching native module.

The x86 Windows bundle was built with `_WIN32_WINNT=0x0501`. `lua.exe` and
`wtop_native.dll` are PE32 i386, and the native module does not hard-import
newer APIs such as `GetTickCount64`. The CPU API
[`GetSystemTimes`](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemtimes)
is documented from XP SP1 onward, so the module resolves it dynamically and
has an NT processor-counter fallback for earlier XP. That fallback matched
`GetSystemTimes` counters on Server 2008 when forced for validation. It is
still unverified on XP itself.

## Known Issues

- On Windows the Processes page still exceeds the CPU performance goal.
  Before the current cache changes, the TUI on its default page used about
  15% of one core on the 10.0.26100 host. Per call, the process list took
  about 15 ms there and the socket table about 6 ms; on Server 2008 the
  display-adapter query took about 18 ms, disks 11 ms and mounts 8 ms.
  Display-adapter identity is now cached for up to 15 seconds. Process paths
  and owner labels are keyed by PID and creation time; owner labels are queried
  again after 30 seconds, or after 5 seconds when lookup failed. The disk
  collector skips absent physical-drive numbers between periodic rescans.
  Warm collector calls and whole-TUI CPU were measured on Server 2008 as noted
  above. The TUI now merges automatic redraws at the selected update interval
  and uses a direct width path for printable ASCII. The Processes page still
  exceeds the 2% single-core goal on that host. Periodic-refresh timing and
  broader hardware measurements are still needed.
- Windows has no pressure or power-zone source and shows them as
  unavailable. Its CPU frequency comes from PDH from Windows 7 / 2008 R2 on;
  older systems report the rated frequency as an estimate. An adapter without
  a WDDM driver, or one that DXGI does not list in a service session, has
  identity and memory but no utilization.
- Windows retains a drive-letter mount row when capacity cannot be read, with
  capacity marked partial instead of zero. Filesystem identity is cached for
  30 seconds on fixed drives. Removable and optical capacity/identity queries
  now use at most two background workers. Their first sample can be pending;
  complete results are cached for 30 seconds, failed results retry after five
  seconds, and expired results are marked stale during a refresh.
  Two permanently blocked devices can prevent other removable probes from
  starting; the collector does not wait for those workers. Working removable
  media has been checked on Server 2008, but the slow and empty cases remain.
  Mapped network drives remain in the list with capacity marked partial, since
  querying a disconnected server can block.
  The wide storage table shows mount quality.
- macOS has no pressure source, no per-process GPU usage, and, without root,
  sockets and workloads only for the caller's own processes. Disk busy time is
  an estimate from summed request service time. Cluster-to-CPU numbering is
  inferred from the performance-level counts.
- The macOS sensor, energy, frequency and workload sources use private
  interfaces. They were validated on M4 and macOS 26.5 only; other chips and
  releases may report them as unavailable.
- A classic console shows line art as ASCII. Text in the console's code page
  (for example Chinese on code page 936) is shown as is; other characters
  appear as `?`. Without `LANG` or `--lang`, a Windows console follows the
  display language only when its code page can show it.

## Baselines Still to Decide

- Windows XP service-pack and CPU architecture variants beyond required x86.
- Windows x64 artifact scope and the versions on which it will be validated.
- Earlier macOS versions and Intel hardware runtime validation.
- Minimum Linux kernel, libc, and CPU architectures.
- Measured CPU, memory, startup, and input-latency budgets for older hardware.

Until those baselines are chosen and validated, the compatibility target should
not be presented as a released platform guarantee.
